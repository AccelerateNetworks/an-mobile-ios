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

struct RenderedFrame {
	/// The Resource block, carried into every post.
	let resource: String
	/// One rendered LogRecord each; the meta record is first. UTF-8 JSON, and maxPostBytes counts
	/// encoded bytes.
	let records: [String]
	/// Names the outbox directory the bodies are staged into.
	let frameId: String
}

/// What is constant for the process that produced a payload.
struct ResourceIdentity {
	let serviceName: String
	let deviceUuid: String
	let version: String
	let platform: String
	/// The app layer's, as they would be on a line the forwarder actually wrote.
	let process: String
	let subsystem: String
}

/// Turns a frame into request bodies.
final class LogFormatter {
	private let identity: ResourceIdentity
	/// Ride the meta record: they change on reprovision.
	var tenant: String = ""
	var `extension`: String = ""
	/// The settings a frame was read under, which the frame id hashes.
	var settings: ForwardSettings
	var replay: Replay?

	init(identity: ResourceIdentity, settings: ForwardSettings) {
		self.identity = identity
		self.settings = settings
	}

	/// Non-null is both "this change needs a replay" and the per-record test it needs. Null while
	/// nothing in ForwardSettings reaches the formatter.
	func hasReEncoding(_ old: ForwardSettings, _ new: ForwardSettings) -> ((Record) -> Bool)? {
		return nil
	}

	func format(_ frame: Frame) -> RenderedFrame {
		let content = frame.records.map { render($0) }
		let frameId = identify(frame, content: content)
		let meta = renderMeta(frame, frameId: frameId)
		return RenderedFrame(resource: resourceBlock, records: [meta] + content.map { $0.withFrameId(frameId) }, frameId: frameId)
	}

	/// Greedy: accumulate rendered records into a body until the next would exceed `maxPostBytes`,
	/// then start another. A single rendered record larger than the bound gets its own body anyway.
	func pack(_ rendered: RenderedFrame, maxPostBytes: Int) -> [String] {
		let prefix = "{\"resourceLogs\":[{\"resource\":\(rendered.resource),\"scopeLogs\":[{\"scope\":{},\"logRecords\":["
		let suffix = "]}]}]}"
		let envelope = prefix.utf8.count + suffix.utf8.count

		var bodies: [String] = []
		var current: [String] = []
		var size = 0
		for record in rendered.records {
			let separator = current.isEmpty ? 0 : 1
			if !current.isEmpty && envelope + size + separator + record.utf8.count > maxPostBytes {
				bodies.append(prefix + current.joined(separator: ",") + suffix)
				current = [record]
				size = record.utf8.count
			} else {
				current.append(record)
				size += separator + record.utf8.count
			}
		}
		if !current.isEmpty {
			bodies.append(prefix + current.joined(separator: ",") + suffix)
		}
		return bodies
	}

	// MARK: - Rendering

	private var resourceBlock: String {
		let attributes = [
			attribute("service.name", identity.serviceName),
			attribute("service.instance.id", identity.deviceUuid),
			attribute("service.version", identity.version),
			attribute("os.name", identity.platform)
		]
		return "{\"attributes\":[\(attributes.joined(separator: ","))]}"
	}

	/// A content record, rendered with a placeholder for the frame id it has not been given yet.
	private func render(_ record: Record) -> ContentRecord {
		var body = Timestamps.rfc3339(localTime: record.localTime, timezone: record.timezone) + " " + record.text
		if record.binaryBytes > 0 {
			body += " <Skipped \(record.binaryBytes) bytes of binary data>"
		}
		var attributes = [
			attribute("level", record.level.severityText),
			attribute("process", record.process),
			attribute("subsystem", record.subsystem)
		]
		if let tag = record.tag {
			attributes.append(attribute("tag", tag))
		}
		let head = "{\"timeUnixNano\":\"\(Timestamps.unixNano(localTime: record.localTime, timezone: record.timezone))\""
			+ ",\"severityNumber\":\(record.level.severityNumber)"
			+ ",\"severityText\":\"\(record.level.severityText)\""
			+ ",\"body\":{\"stringValue\":\(LogFormatter.quote(body))}"
			+ ",\"attributes\":["
		return ContentRecord(head: head, tail: "," + attributes.joined(separator: ",") + "]}")
	}

	/// Timestamped at the first record the frame traversed, kept or filtered. Its severity is frame
	/// health, not content health.
	private func renderMeta(_ frame: Frame, frameId: String) -> String {
		let localTime = frame.firstLocalTime ?? Timestamps.currentLocalTime()
		let timezone = frame.firstTimezone ?? frame.declaredTimezone
		let level: Level = frame.lostBytes > 0 ? .warning : .message
		let stamp = Timestamps.rfc3339(localTime: localTime, timezone: timezone)
		let summary = "\(stamp) [\(LogForwarding.forwarderTag)] \(frame.records.count) records, "
			+ "\(frame.startOffset)-\(frame.endOffset), \(frame.lostBytes) bytes lost"
		let attributes = [
			attribute("process", identity.process),
			attribute("subsystem", identity.subsystem),
			attribute("tag", LogForwarding.forwarderTag),
			attribute("level", level.severityText),
			attribute("frame_id", frameId),
			attribute("cursor_file", frame.cursor.file.description),
			attribute("cursor_from", String(frame.startOffset)),
			attribute("cursor_to", String(frame.endOffset)),
			attribute("lost_bytes", String(frame.lostBytes)),
			attribute("tenant", tenant),
			attribute("extension", self.extension)
		]
		return "{\"timeUnixNano\":\"\(Timestamps.unixNano(localTime: localTime, timezone: timezone))\""
			+ ",\"severityNumber\":\(level.severityNumber)"
			+ ",\"severityText\":\"\(level.severityText)\""
			+ ",\"body\":{\"stringValue\":\(LogFormatter.quote(summary))}"
			+ ",\"attributes\":[\(attributes.joined(separator: ","))]}"
	}

	/// The SHA-256, lowercase hex, of the frame's file id, offsets, the digest of the settings it
	/// was read under, the digest of the replay where one was in force, and the rendered LogRecords
	/// in order, excluding the meta record which carries it. Composite values contribute their own
	/// digest rather than their contents.
	private func identify(_ frame: Frame, content: [ContentRecord]) -> String {
		var hasher = SHA256()
		let head = "\(frame.cursor.file.description)\n\(frame.startOffset)\n\(frame.endOffset)\n"
		hasher.update(data: Data(head.utf8))
		hasher.update(data: settings.sha256)
		if let replay = replay {
			hasher.update(data: replay.sha256)
		}
		hasher.update(data: Data(content.map { $0.head + $0.tail }.joined(separator: "\n").utf8))
		return hasher.finalize().hex
	}

	private func attribute(_ key: String, _ value: String) -> String {
		return "{\"key\":\"\(key)\",\"value\":{\"stringValue\":\(LogFormatter.quote(value))}}"
	}

	static func quote(_ value: String) -> String {
		var out = "\""
		for scalar in value.unicodeScalars {
			switch scalar {
			case "\"": out += "\\\""
			case "\\": out += "\\\\"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			default:
				if scalar.value < 0x20 || scalar.value == 0x7F {
					out += String(format: "\\u%04x", scalar.value)
				} else {
					out.unicodeScalars.append(scalar)
				}
			}
		}
		return out + "\""
	}
}

/// A content record is rendered before its frame id is known, because the id hashes it.
private struct ContentRecord {
	let head: String
	let tail: String

	func withFrameId(_ frameId: String) -> String {
		return head + "{\"key\":\"frame_id\",\"value\":{\"stringValue\":\"\(frameId)\"}}" + tail
	}
}

/// The header is local wall clock with no offset, so every instant here is resolved against the
/// offset the reader stamped.
enum Timestamps {
	/// "2026-09-28 14:30:12:345" and "-07:00" to "2026-09-28T14:30:12.345-07:00".
	static func rfc3339(localTime: String, timezone: String) -> String {
		var characters = Array(localTime)
		guard characters.count == 23 else { return localTime + timezone }
		characters[10] = "T"
		characters[19] = "."
		return String(characters) + timezone
	}

	static func unixNano(localTime: String, timezone: String) -> String {
		let digits = Array(localTime)
		guard digits.count == 23 else { return "0" }
		func number(_ from: Int, _ count: Int) -> Int {
			return Int(String(digits[from..<(from + count)])) ?? 0
		}
		let days = daysFromCivil(year: number(0, 4), month: number(5, 2), day: number(8, 2))
		let seconds = Int64(days) * 86400
			+ Int64(number(11, 2)) * 3600
			+ Int64(number(14, 2)) * 60
			+ Int64(number(17, 2))
			- Int64(offsetSeconds(timezone))
		return String(seconds * 1_000_000_000 + Int64(number(20, 3)) * 1_000_000)
	}

	static func offsetSeconds(_ timezone: String) -> Int {
		let characters = Array(timezone)
		guard characters.count == 6, let hours = Int(String(characters[1...2])), let minutes = Int(String(characters[4...5])) else {
			return 0
		}
		let magnitude = hours * 3600 + minutes * 60
		return characters[0] == "-" ? -magnitude : magnitude
	}

	/// The header form, for a frame that traversed no record to take an instant from.
	static func currentLocalTime() -> String {
		let now = Date()
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone.current
		let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
		return String(format: "%04d-%02d-%02d %02d:%02d:%02d:%03d",
					  parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
					  parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
					  (parts.nanosecond ?? 0) / 1_000_000)
	}

	private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
		let shifted = year - (month <= 2 ? 1 : 0)
		let era = (shifted >= 0 ? shifted : shifted - 399) / 400
		let yearOfEra = shifted - era * 400
		let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
		let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
		return era * 146097 + dayOfEra - 719468
	}
}
