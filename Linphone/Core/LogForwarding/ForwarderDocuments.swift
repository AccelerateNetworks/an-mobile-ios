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

import CryptoKit
import Foundation

/// Below the bound, a record must pass the new settings and must either not have passed the old ones
/// or be re-encoded under them.
struct Replay {
	let previous: ForwardSettings
	/// `maxFile` and `maxOffset` together name a position: an offset alone means nothing across a
	/// rotation.
	let maxFile: FileId
	let maxOffset: Int64
	/// Null while nothing in ForwardSettings reaches the formatter.
	let isReEncoded: ((Record) -> Bool)?

	func forwards(_ record: Record, settings: ForwardSettings) -> Bool {
		guard settings.accepts(record) else { return false }
		if !previous.accepts(record) { return true }
		return isReEncoded?(record) ?? false
	}

	/// What the frame id hashes: the previous settings' digest, `maxFile` and `maxOffset`.
	var sha256: Data {
		var hasher = SHA256()
		hasher.update(data: previous.sha256)
		hasher.update(data: Data("\(maxFile.description)\n\(maxOffset)".utf8))
		return Data(hasher.finalize())
	}
}

struct SettingsDocument: Codable {
	let `default`: String
	let levels: [String: String]
	let tags: [String: String]

	init(_ settings: ForwardSettings) {
		self.default = settings.default.configToken
		self.levels = settings.levels.mapValues { $0.configToken }
		self.tags = settings.tags.mapValues { $0.configToken }
	}

	var settings: ForwardSettings {
		return ForwardSettings(
			default: Level.threshold(self.default) ?? .warning,
			levels: levels.compactMapValues { Level.threshold($0) },
			tags: tags.compactMapValues { Level.threshold($0) }
		)
	}
}

struct ReplayDocument: Codable {
	let previous: SettingsDocument
	let maxFile: String
	let maxOffset: Int64
}

struct StateDocument: Codable {
	let cursor: String?
	let declaredTimezone: String?
	let replay: ReplayDocument?

	enum CodingKeys: String, CodingKey {
		case cursor, declaredTimezone, replay
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(cursor, forKey: .cursor)
		try container.encode(declaredTimezone, forKey: .declaredTimezone)
		try container.encode(replay, forKey: .replay)
	}
}

/// What the forwarder must remember across runs. Written when the timezone in force changes, when
/// the active cursor changes, or when a replay begins or ends.
final class ForwarderState {
	private let url: URL

	private(set) var cursor: String?
	private(set) var declaredTimezone: String?
	private(set) var replay: Replay?

	init(directory: URL) {
		url = directory.appendingPathComponent("state.json")
		guard let data = try? Data(contentsOf: url),
			  let document = try? JSONDecoder().decode(StateDocument.self, from: data) else {
			return
		}
		cursor = document.cursor
		declaredTimezone = document.declaredTimezone
		if let stored = document.replay, let maxFile = FileId(rendered: stored.maxFile) {
			replay = Replay(previous: stored.previous.settings, maxFile: maxFile, maxOffset: stored.maxOffset, isReEncoded: nil)
		}
	}

	func updateTimezone(_ value: String) {
		guard declaredTimezone != value else { return }
		declaredTimezone = value
		persist()
	}

	/// A new cursor's document is written before the state entry points at it, so a crash between
	/// the two leaves a stale pointer rather than a dangling one.
	func updateCursor(_ value: String?) {
		guard cursor != value else { return }
		cursor = value
		persist()
	}

	func updateReplay(_ value: Replay?) {
		replay = value
		persist()
	}

	func persist() {
		let document = StateDocument(
			cursor: cursor,
			declaredTimezone: declaredTimezone,
			replay: replay.map {
				ReplayDocument(previous: SettingsDocument($0.previous), maxFile: $0.maxFile.description, maxOffset: $0.maxOffset)
			}
		)
		guard let data = try? JSONEncoder().encode(document) else { return }
		try? DurableFile.write(data, to: url)
		DurableFile.excludeFromBackup(url)
	}
}

struct DispatchDocument: Codable {
	let notBefore: String?
	let failures: Int
	let outageStart: String?
	let lastOutcome: String?

	enum CodingKeys: String, CodingKey {
		case notBefore, failures, outageStart, lastOutcome
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(notBefore, forKey: .notBefore)
		try container.encode(failures, forKey: .failures)
		try container.encode(outageStart, forKey: .outageStart)
		try container.encode(lastOutcome, forKey: .lastOutcome)
	}
}

/// A third document, because outcomes arrive from the transport rather than from the run and can
/// land in a process where no run is active.
final class DispatchState {
	private static let formatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return formatter
	}()

	private let url: URL
	private let lock = NSLock()

	private(set) var notBefore: Date?
	private(set) var failures: Int = 0
	private(set) var outageStart: Date?
	private(set) var lastOutcome: String?

	init(directory: URL) {
		url = directory.appendingPathComponent("dispatch.json")
		guard let data = try? Data(contentsOf: url),
			  let document = try? JSONDecoder().decode(DispatchDocument.self, from: data) else {
			return
		}
		notBefore = document.notBefore.flatMap { DispatchState.formatter.date(from: $0) }
		failures = document.failures
		outageStart = document.outageStart.flatMap { DispatchState.formatter.date(from: $0) }
		lastOutcome = document.lastOutcome
	}

	var isBackedOff: Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let notBefore = notBefore else { return false }
		return notBefore > Date()
	}

	/// A dispatch failure pushes `notBefore` out exponentially with jitter, capped at `max_backoff`.
	/// `Retry-After` replaces the computed value, being an instruction rather than a guess.
	func recordFailure(outcome: String, retryAfter: TimeInterval?, maxBackoff: TimeInterval) {
		lock.lock()
		failures += 1
		if outageStart == nil {
			outageStart = Date()
		}
		lastOutcome = outcome
		let base = Swift.min(maxBackoff, pow(2.0, Double(Swift.min(failures, 16))))
		let jittered = base * Double.random(in: 0.5...1.0)
		notBefore = Date().addingTimeInterval(retryAfter ?? jittered)
		lock.unlock()
		persist()
	}

	/// Returns the outage worth reporting, which is one that reached the ceiling.
	func recordSuccess(outcome: String, maxBackoff: TimeInterval) -> (duration: TimeInterval, failures: Int, lastOutcome: String)? {
		lock.lock()
		var report: (TimeInterval, Int, String)?
		if let start = outageStart, let previous = lastOutcome, reachedCeiling(maxBackoff: maxBackoff) {
			report = (Date().timeIntervalSince(start), failures, previous)
		}
		failures = 0
		notBefore = nil
		outageStart = nil
		lastOutcome = outcome
		lock.unlock()
		persist()
		return report
	}

	/// Called with the lock held.
	private func reachedCeiling(maxBackoff: TimeInterval) -> Bool {
		return pow(2.0, Double(Swift.min(failures, 16))) >= maxBackoff
	}

	private func persist() {
		lock.lock()
		let document = DispatchDocument(
			notBefore: notBefore.map { DispatchState.formatter.string(from: $0) },
			failures: failures,
			outageStart: outageStart.map { DispatchState.formatter.string(from: $0) },
			lastOutcome: lastOutcome
		)
		lock.unlock()
		guard let data = try? JSONEncoder().encode(document) else { return }
		try? DurableFile.write(data, to: url)
		DurableFile.excludeFromBackup(url)
	}
}
