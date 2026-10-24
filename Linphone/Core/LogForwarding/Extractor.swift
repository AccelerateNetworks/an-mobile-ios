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

/// Compiled in; owns the record's shape. Latin-1 never leaves here: a window is decoded one byte to
/// one character so that a match offset is a byte offset, and each matched record is decoded as
/// UTF-8 for the `Record` returned.
final class Extractor {
	private static let timestamp = "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{3}"
	private static let pattern =
		"("
		+ "(" + timestamp + ")"
		+ " \\[([^/\\x{0D}\\x{0A}]*)/([^\\]\\x{0D}\\x{0A}]*)\\]"
		+ " (FATAL|ERROR|WARNING|MESSAGE|DEBUG)"
		+ " ((?:\\[([^\\]\\x{0D}\\x{0A}]*)\\])?.*?)"
		+ ")"
		+ "\\x{0A}?"
		+ "(?=(" + timestamp + " \\[)|\\z)"

	private enum Group {
		static let record = 1
		static let timestamp = 2
		static let process = 3
		static let subsystem = 4
		static let level = 5
		static let body = 6
		static let tag = 7
		static let lookahead = 8
	}

	private let regex: NSRegularExpression

	private var cachedHandle: Handle = -1
	private var cachedStart: Int64 = -1
	private var cachedCount: Int = -1
	private var cachedText: String = ""

	init() {
		// swiftlint:disable:next force_try
		regex = try! NSRegularExpression(pattern: Extractor.pattern, options: [.dotMatchesLineSeparators])
	}

	/// The next whole record at or after `from`, extracted and decoded. A record is bounded by the
	/// following header; where the match ran to the window's end instead, `acceptWindowEnd` decides
	/// whether that bounds it. Nil otherwise.
	func next(window: Window, from: Int64, acceptWindowEnd: Bool) -> Record? {
		let text = latin1(window)
		let length = text.utf16.count
		let searchStart = Int(from - window.start)
		guard searchStart >= 0, searchStart <= length else { return nil }

		let searchRange = NSRange(location: searchStart, length: length - searchStart)
		guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else { return nil }
		if match.range(at: Group.lookahead).location == NSNotFound && !acceptWindowEnd { return nil }

		let recordRange = match.range(at: Group.record)
		let bodyRange = match.range(at: Group.body)
		guard recordRange.location != NSNotFound, bodyRange.location != NSNotFound else { return nil }

		let bodyStart = bodyRange.location
		let bodyEnd = bodyStart + bodyRange.length
		let valid = Extractor.utf8PrefixLength(window.bytes, from: bodyStart, to: bodyEnd)
		let body = String(decoding: window.bytes[bodyStart..<(bodyStart + valid)], as: UTF8.self)

		var tag: String?
		let tagRange = match.range(at: Group.tag)
		if tagRange.location != NSNotFound {
			let tagEnd = tagRange.location + tagRange.length
			let tagValid = Extractor.utf8PrefixLength(window.bytes, from: tagRange.location, to: tagEnd)
			let raw = String(decoding: window.bytes[tagRange.location..<(tagRange.location + tagValid)], as: UTF8.self)
			tag = Record.normaliseTag(raw)
		}

		guard let level = Level.recordToken(substring(text, match.range(at: Group.level))) else { return nil }

		return Record(
			localTime: substring(text, match.range(at: Group.timestamp)),
			process: substring(text, match.range(at: Group.process)),
			subsystem: substring(text, match.range(at: Group.subsystem)),
			tag: tag,
			level: level,
			declaredTimezone: Extractor.declaredTimezone(tag: tag, text: body),
			timezone: "",
			text: body,
			binaryBytes: Int64(bodyEnd - bodyStart - valid),
			orphanedBytes: 0,
			startOffset: window.start + Int64(recordRange.location),
			endOffset: window.start + Int64(match.range.location + match.range.length)
		)
	}

	private func latin1(_ window: Window) -> String {
		if window.handle == cachedHandle && window.start == cachedStart && window.bytes.count == cachedCount {
			return cachedText
		}
		var scalars = String.UnicodeScalarView()
		scalars.reserveCapacity(window.bytes.count)
		for byte in window.bytes {
			scalars.append(UnicodeScalar(byte))
		}
		cachedText = String(scalars)
		cachedHandle = window.handle
		cachedStart = window.start
		cachedCount = window.bytes.count
		return cachedText
	}

	/// The match ranges are UTF-16 offsets into the Latin-1 decoding, where one code unit is one byte.
	private func substring(_ text: String, _ range: NSRange) -> String {
		guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
		return String(text[swiftRange])
	}

	/// The anchor test runs against the decoded text, not the pattern, and keys on the tag and the
	/// message so that any process's anchor is adopted.
	static func declaredTimezone(tag: String?, text: String) -> String? {
		guard tag == "forwarder", let marker = text.range(of: "tz anchor ") else { return nil }
		let offset = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
		return isOffset(offset) ? offset : nil
	}

	static func isOffset(_ value: String) -> Bool {
		let characters = Array(value)
		guard characters.count == 6, characters[0] == "+" || characters[0] == "-", characters[3] == ":" else { return false }
		for index in [1, 2, 4, 5] where !characters[index].isNumber {
			return false
		}
		return true
	}

	/// Bytes of `[from, to)` that decode as UTF-8, stopping at the first byte that does not.
	static func utf8PrefixLength(_ bytes: [UInt8], from: Int, to: Int) -> Int {
		var index = from
		while index < to {
			let lead = bytes[index]
			var width = 0
			if lead < 0x80 {
				width = 1
			} else if lead >= 0xC2 && lead <= 0xDF {
				width = 2
			} else if lead >= 0xE0 && lead <= 0xEF {
				width = 3
			} else if lead >= 0xF0 && lead <= 0xF4 {
				width = 4
			} else {
				break
			}
			if index + width > to { break }
			var valid = true
			for offset in 1..<width where (bytes[index + offset] & 0xC0) != 0x80 {
				valid = false
			}
			if valid && width == 3 {
				let second = bytes[index + 1]
				if lead == 0xE0 && second < 0xA0 { valid = false }
				if lead == 0xED && second > 0x9F { valid = false }
			}
			if valid && width == 4 {
				let second = bytes[index + 1]
				if lead == 0xF0 && second < 0x90 { valid = false }
				if lead == 0xF4 && second > 0x8F { valid = false }
			}
			if !valid { break }
			index += width
		}
		return index - from
	}
}
