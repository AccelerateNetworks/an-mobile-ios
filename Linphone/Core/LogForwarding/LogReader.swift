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
import linphonesw

/// Turns bytes into records and owns its position. Files, windows, offsets and limits are its
/// business; where a record begins and ends is the extractor's.
final class LogReader {
	private static let defaultWindowSize = 256 * 1024

	let dir: String
	let prefix: String
	private let extractor: Extractor
	private let documents: URL
	private let state: ForwarderState

	/// Bounds raw record bytes KEPT per read. -1 means unbounded.
	var softLimit: Int64

	private(set) var cursor: Cursor
	private var handle: Handle?
	private var handleId: FileId?
	private var timezoneInForce: String
	private var pendingLostBytes: Int64 = 0
	private var windowSize = LogReader.defaultWindowSize

	/// `declaredTimezone` is the offset in force at the first byte read: the cursor's value, the
	/// state entry's otherwise, or the device's current offset where neither is persisted.
	/// `softLimit` is required, so nobody gets an unbounded read by not noticing a default.
	init(dir: String, prefix: String, extractor: Extractor, declaredTimezone: String, softLimit: Int64,
		 documents: URL, state: ForwarderState) {
		self.dir = dir
		self.prefix = prefix
		self.extractor = extractor
		self.documents = documents
		self.state = state
		self.softLimit = softLimit
		self.timezoneInForce = declaredTimezone
		self.cursor = LogReader.resolveCursor(dir: dir, prefix: prefix, documents: documents, state: state,
											  declaredTimezone: declaredTimezone)
		self.timezoneInForce = cursor.declaredTimezone.isEmpty ? declaredTimezone : cursor.declaredTimezone
		state.updateCursor(cursor.file.description)
	}

	deinit {
		closeHandle()
	}

	/// A widened forward level admits records already in the file, below the committed offset, so a
	/// replay starts at the oldest available byte.
	func resetToOldest() {
		closeHandle()
		guard let path = InodeUtils.paths(dir: dir, prefix: prefix).first(where: { InodeUtils.idOf(path: $0) != nil }),
			  let id = InodeUtils.idOf(path: path) else {
			return
		}
		cursor = Cursor(file: id, directory: documents, declaredTimezone: timezoneInForce)
		cursor.persist()
		state.updateCursor(cursor.file.description)
	}

	// MARK: - Reading

	func read(settings: ForwardSettings, replay: Replay?) -> Frame {
		windowSize = LogReader.defaultWindowSize
		prepare()
		let frameCursor = cursor
		let start = cursor.offset
		guard let handle = handle else {
			return frame(status: .caughtUp, cursor: frameCursor, records: [], start: start, end: start,
						 payload: 0, filtered: 0, first: nil, successor: nil)
		}

		let fileSize = InodeUtils.size(handle: handle)
		var records: [Record] = []
		var payload: Int64 = 0
		var filtered: Int64 = 0
		var first: (String, String)?
		var position = start
		var reachedLimit = false
		var held = false
		let successor = observeSuccessor()

		while position < fileSize {
			let length = Int(Swift.min(Int64(windowSize), fileSize - position))
			let bytes = InodeUtils.read(handle: handle, at: position, count: length)
			if bytes.isEmpty { break }
			let window = Window(handle: handle, start: position, end: position + Int64(bytes.count), bytes: bytes)

			var at = position
			var produced = false
			while let found = extractor.next(window: window, from: at, acceptWindowEnd: false) {
				produced = true
				let record = stamp(found, from: at, chased: frameCursor.chased)
				if first == nil { first = (record.localTime, record.timezone) }
				if forwards(record, settings: settings, replay: replay, cursor: frameCursor) {
					records.append(record)
					payload += record.span
				} else {
					filtered += 1
				}
				at = record.endOffset
				if softLimit >= 0 && payload >= softLimit {
					reachedLimit = true
					break
				}
			}

			if produced { position = at }
			if reachedLimit { break }
			if !produced {
				if window.end >= fileSize {
					if extractor.next(window: window, from: position, acceptWindowEnd: true) != nil {
						held = true
					} else if successor != nil {
						reportTrailingOrphan(from: position, to: fileSize, chased: frameCursor.chased)
						position = fileSize
					}
					break
				}
				windowSize *= 2
				continue
			}
			if at < window.end && window.end >= fileSize {
				held = true
				break
			}
		}

		var status: ReadStatus = .caughtUp
		if reachedLimit {
			status = .moreAvailable
		} else if held {
			status = .holdingPartial
		} else if position >= fileSize && successor != nil {
			status = .fileComplete
		}

		cursor.offset = position
		return frame(status: status, cursor: frameCursor, records: records, start: start, end: position,
					 payload: payload, filtered: filtered, first: first, successor: successor)
	}

	/// The chase. The only caller that passes `acceptWindowEnd` true, and only with a window whose
	/// end is the file's end.
	func readLastElseRead(settings: ForwardSettings, replay: Replay?) -> Frame {
		prepare()
		guard let handle = handle else {
			return read(settings: settings, replay: replay)
		}
		let frameCursor = cursor
		let start = cursor.offset
		let fileSize = InodeUtils.size(handle: handle)
		guard start < fileSize else {
			return read(settings: settings, replay: replay)
		}

		let bytes = InodeUtils.read(handle: handle, at: start, count: Int(fileSize - start))
		guard !bytes.isEmpty else {
			return read(settings: settings, replay: replay)
		}
		let window = Window(handle: handle, start: start, end: start + Int64(bytes.count), bytes: bytes)
		guard let found = extractor.next(window: window, from: start, acceptWindowEnd: true),
			  found.endOffset >= window.end else {
			return read(settings: settings, replay: replay)
		}

		let record = stamp(found, from: start, chased: frameCursor.chased)
		var records: [Record] = []
		var payload: Int64 = 0
		var filtered: Int64 = 0
		if forwards(record, settings: settings, replay: replay, cursor: frameCursor) {
			records.append(record)
			payload = record.span
		} else {
			filtered = 1
		}

		let successor = observeSuccessor()
		cursor.offset = record.endOffset
		return frame(status: .caughtUp, cursor: frameCursor, records: records, start: start, end: record.endOffset,
					 payload: payload, filtered: filtered, first: (record.localTime, record.timezone), successor: successor)
	}

	// MARK: - Framing

	private func frame(status: ReadStatus, cursor: Cursor, records: [Record], start: Int64, end: Int64,
					   payload: Int64, filtered: Int64, first: (String, String)?, successor: FileId?) -> Frame {
		let lost = pendingLostBytes
		pendingLostBytes = 0
		return Frame(
			status: status,
			records: records,
			cursor: cursor,
			successor: successor,
			startOffset: start,
			endOffset: end,
			declaredTimezone: timezoneInForce,
			payloadSize: payload,
			consumedSize: end - start,
			filteredCount: filtered,
			lostBytes: lost,
			firstLocalTime: first?.0,
			firstTimezone: first?.1
		)
	}

	/// The reader adopts, then stamps. One branch, no special case for the anchor, because
	/// `localtime()` formatted the anchor's own header in the new zone too.
	private func stamp(_ record: Record, from: Int64, chased: Bool) -> Record {
		var stamped = record
		if let declared = record.declaredTimezone {
			timezoneInForce = declared
		}
		stamped.timezone = timezoneInForce
		stamped.orphanedBytes = record.startOffset - from
		if stamped.orphanedBytes > 0 {
			Log.warn("[\(LogForwarding.forwarderTag)] discarded \(stamped.orphanedBytes) headerless bytes at "
					 + "\(from)-\(record.startOffset) on \(cursor.file.description), chased commit below: \(chased)")
		}
		return stamped
	}

	private func reportTrailingOrphan(from: Int64, to: Int64, chased: Bool) {
		Log.warn("[\(LogForwarding.forwarderTag)] discarded \(to - from) headerless bytes at "
				 + "\(from)-\(to) closing \(cursor.file.description), chased commit: \(chased)")
	}

	private func forwards(_ record: Record, settings: ForwardSettings, replay: Replay?, cursor: Cursor) -> Bool {
		guard let replay = replay, isBelowBound(replay, cursor: cursor, offset: record.endOffset) else {
			return settings.accepts(record)
		}
		return replay.forwards(record, settings: settings)
	}

	/// The bound is a position: an offset alone means nothing across a rotation.
	private func isBelowBound(_ replay: Replay, cursor: Cursor, offset: Int64) -> Bool {
		let paths = InodeUtils.paths(dir: dir, prefix: prefix)
		guard let theirs = paths.firstIndex(where: { InodeUtils.idOf(path: $0) == replay.maxFile }) else {
			return false
		}
		guard let mine = paths.firstIndex(where: { InodeUtils.idOf(path: $0) == cursor.file }) else {
			return false
		}
		if mine < theirs { return true }
		if mine > theirs { return false }
		return offset <= replay.maxOffset
	}

	// MARK: - File lifecycle

	/// The reader always has exactly one inode it still needs: `Complete ? Successor : file`.
	private func prepare() {
		collectStaleCursors()
		if handleId != cursor.file {
			closeHandle()
			handle = InodeUtils.openById(dir: dir, prefix: prefix, id: cursor.file)
			handleId = handle == nil ? nil : cursor.file
		}

		guard let open = handle else {
			let unread = Swift.max(0, LogReader.maxFileSize - cursor.committedOffset)
			Log.warn("[\(LogForwarding.forwarderTag)] \(cursor.file.description) was unlinked with bytes we never read; "
					 + "restarting at the oldest available file")
			restart(lostBytes: unread)
			return
		}

		guard cursor.isComplete(fileSize: InodeUtils.size(handle: open)), let successor = cursor.successor else {
			return
		}
		closeHandle()
		guard let next = InodeUtils.openById(dir: dir, prefix: prefix, id: successor) else {
			Log.warn("[\(LogForwarding.forwarderTag)] successor \(successor.description) was destroyed before we read any of it; "
					 + "restarting at the oldest available file")
			restart(lostBytes: LogReader.maxFileSize)
			return
		}
		handle = next
		handleId = successor
		adopt(cursor: Cursor.load(file: successor, directory: documents)
			?? Cursor(file: successor, directory: documents, declaredTimezone: timezoneInForce))
	}

	private func restart(lostBytes: Int64) {
		closeHandle()
		let paths = InodeUtils.paths(dir: dir, prefix: prefix)
		guard let path = paths.first(where: { InodeUtils.idOf(path: $0) != nil }),
			  let id = InodeUtils.idOf(path: path),
			  let open = InodeUtils.openById(dir: dir, prefix: prefix, id: id) else {
			return
		}
		pendingLostBytes += lostBytes
		handle = open
		handleId = id
		adopt(cursor: Cursor.load(file: id, directory: documents)
			?? Cursor(file: id, directory: documents, declaredTimezone: timezoneInForce))
	}

	private func adopt(cursor next: Cursor) {
		cursor = next
		if !next.declaredTimezone.isEmpty {
			timezoneInForce = next.declaredTimezone
		}
		next.persist()
		state.updateCursor(next.file.description)
	}

	/// `1.log` is the older index, so our file's successor is whatever `2.log` currently is.
	private func observeSuccessor() -> FileId? {
		let paths = InodeUtils.paths(dir: dir, prefix: prefix)
		guard let index = paths.firstIndex(where: { InodeUtils.idOf(path: $0) == cursor.file }), index == 0 else {
			return cursor.successor
		}
		guard let successor = InodeUtils.idOf(path: paths[1]) else { return cursor.successor }
		cursor.observe(successor: successor)
		return successor
	}

	/// A cursor document is deleted once the inode it tracks no longer exists.
	private func collectStaleCursors() {
		var live = Set<String>([cursor.file.documentName])
		for path in InodeUtils.paths(dir: dir, prefix: prefix) {
			if let id = InodeUtils.idOf(path: path) {
				live.insert(id.documentName)
			}
		}
		for name in Cursor.documentNames(in: documents) where !live.contains(name) {
			try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
		}
	}

	private func closeHandle() {
		if let open = handle {
			close(open)
		}
		handle = nil
		handleId = nil
	}

	/// The unread tail of a destroyed file cannot be measured, so the file-size setting rotation
	/// enforces stands in for it.
	private static var maxFileSize: Int64 {
		return Int64(Core.getLogCollectionMaxFileSize)
	}

	private static func resolveCursor(dir: String, prefix: String, documents: URL, state: ForwarderState,
									  declaredTimezone: String) -> Cursor {
		if let rendered = state.cursor, let id = FileId(rendered: rendered), let existing = Cursor.load(file: id, directory: documents) {
			return existing
		}
		let paths = InodeUtils.paths(dir: dir, prefix: prefix)
		if let path = paths.first(where: { InodeUtils.idOf(path: $0) != nil }), let id = InodeUtils.idOf(path: path) {
			return Cursor.load(file: id, directory: documents)
				?? Cursor(file: id, directory: documents, declaredTimezone: declaredTimezone)
		}
		return Cursor(file: FileId(device: 0, inode: 0), directory: documents, declaredTimezone: declaredTimezone)
	}
}
