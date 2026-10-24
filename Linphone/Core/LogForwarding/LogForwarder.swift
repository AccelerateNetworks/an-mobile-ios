/*
* Copyright (c) 2026 Accelerate Networks LLC
*
* This file is part of linphone
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

import Foundation

/// Drives the loop and owns delivery policy. Every way a run ends is safe, because the cursor has
/// advanced only past spans whose bodies are already durable.
final class LogForwarder {
	/// Waits out a flush in progress. A margin rather than a derivation; do not tune below about
	/// 100 ms.
	static let settleInterval: TimeInterval = 0.25

	let reader: LogReader
	let formatter: LogFormatter
	let outbox: Outbox
	let dispatcher: Dispatcher
	var maxPostBytes: Int

	private let state: ForwarderState
	private(set) var settings: ForwardSettings
	private(set) var replay: Replay?
	/// A forwarder a `supersede` replaced is invalid from that moment.
	private var invalidated = false
	/// Set from whatever thread the scheduler expires the run on, read by the run.
	private let stopLock = NSLock()
	private var stopRequested = false

	private var stopping: Bool {
		stopLock.lock()
		defer { stopLock.unlock() }
		return stopRequested
	}

	init(reader: LogReader, formatter: LogFormatter, outbox: Outbox, dispatcher: Dispatcher,
		 maxPostBytes: Int, state: ForwarderState, settings: ForwardSettings) {
		self.reader = reader
		self.formatter = formatter
		self.outbox = outbox
		self.dispatcher = dispatcher
		self.maxPostBytes = maxPostBytes
		self.state = state
		self.settings = settings
		self.replay = state.replay
	}

	/// Drains until CaughtUp or stopped.
	func start() {
		guard !invalidated else { return }
		stopLock.lock()
		stopRequested = false
		stopLock.unlock()

		if dispatcher.destination.isEmpty {
			outbox.clear()
			return
		}
		dispatcher.drain()
		outbox.sweep()
		for directory in outbox.pending() {
			dispatcher.dispatch(directory)
		}

		while !stopping && !invalidated {
			var frame = reader.read(settings: settings, replay: replay)
			commitAndDispatch(frame)
			if frame.status == .caughtUp { break }
			if frame.status == .holdingPartial {
				if frame.successor == nil {
					Thread.sleep(forTimeInterval: LogForwarder.settleInterval)
				}
				frame = reader.readLastElseRead(settings: settings, replay: replay)
				commitAndDispatch(frame)
				if frame.status == .caughtUp { break }
			}
		}
	}

	/// A run stops where it is rather than draining. Whatever it had already made durable stays
	/// pending for the next run to dispatch.
	func stop() {
		stopLock.lock()
		stopRequested = true
		stopLock.unlock()
	}

	/// A new forwarder with `Replay` set where `requiresReplay` or `hasReEncoding` says so;
	/// otherwise this, with settings replaced.
	func supersede(settings next: ForwardSettings) -> LogForwarder {
		let reEncoded = formatter.hasReEncoding(settings, next)
		guard settings.requiresReplay(next) || reEncoded != nil else {
			settings = next
			formatter.settings = next
			return self
		}

		invalidated = true
		stop()
		let marker = Replay(previous: settings, maxFile: reader.cursor.file,
							maxOffset: reader.cursor.committedOffset, isReEncoded: reEncoded)
		state.updateReplay(marker)
		reader.resetToOldest()
		let replacement = LogForwarder(reader: reader, formatter: formatter, outbox: outbox, dispatcher: dispatcher,
									   maxPostBytes: maxPostBytes, state: state, settings: next)
		replacement.replay = marker
		formatter.settings = next
		formatter.replay = marker
		return replacement
	}

	// MARK: - The run

	private func commitAndDispatch(_ frame: Frame) {
		if !frame.records.isEmpty || frame.lostBytes > 0 {
			formatter.settings = settings
			formatter.replay = replay
			let rendered = formatter.format(frame)
			let bodies = formatter.pack(rendered, maxPostBytes: maxPostBytes)
			do {
				let directory = try outbox.write(frameId: rendered.frameId, bodies: bodies)
				commit(frame)
				dispatcher.dispatch(directory)
			} catch {
				Log.error("[\(LogForwarding.forwarderTag)] could not make \(frame.startOffset)-\(frame.endOffset) durable: \(error.localizedDescription)")
			}
		} else if frame.consumedSize > 0 {
			commit(frame)
		}
	}

	private func commit(_ frame: Frame) {
		frame.cursor.commit(offset: frame.endOffset,
							successor: frame.successor,
							chased: frame.status == .caughtUp,
							declaredTimezone: frame.declaredTimezone)
		if state.declaredTimezone != frame.declaredTimezone {
			state.updateTimezone(frame.declaredTimezone)
		}
		endReplayIfPassed(frame)
	}

	/// The replay is live until the cursor reaches the bound, or until `maxFile` is gone, which
	/// means everything still readable was written after it.
	private func endReplayIfPassed(_ frame: Frame) {
		guard let marker = replay else { return }
		let reached = frame.cursor.file == marker.maxFile && frame.cursor.committedOffset >= marker.maxOffset
		let gone = InodeUtils.find(dir: reader.dir, prefix: reader.prefix, id: marker.maxFile) == nil
		guard reached || gone else { return }
		replay = nil
		formatter.replay = nil
		state.updateReplay(nil)
	}
}
