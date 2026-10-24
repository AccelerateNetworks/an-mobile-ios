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

/// A contiguous positional read. The reader owns it and sizes it.
struct Window {
	/// The open descriptor it is a view of; rotation cannot change it.
	let handle: Handle
	/// File offset of byte 0.
	let start: Int64
	/// start + size.
	let end: Int64
	let bytes: [UInt8]
}

struct Record {
	/// Verbatim, "2026-09-28 14:30:12:345"; no zone applied.
	let localTime: String
	/// `getprogname()`, the bracket's head.
	let process: String
	/// The bracket's tail; what `levelFor()` keys on.
	let subsystem: String
	/// The message's leading [marker], where there is one, lowercased with non-alphanumerics
	/// removed. Promoted, never removed from the text.
	let tag: String?
	let level: Level
	/// Non-null when this record is a tz anchor: the offset it declares.
	let declaredTimezone: String?
	/// The offset in force here, stamped by the reader. NOT a byte offset.
	var timezone: String
	/// UTF-8, header stripped, ending at the first undecodable byte.
	let text: String
	/// Bytes dropped from the end because they could not be decoded; 0 normally.
	let binaryBytes: Int64
	/// Bytes immediately below startOffset that carried no header and could not be extracted; 0
	/// normally. Carried by the record that follows the span, kept or filtered.
	var orphanedBytes: Int64
	let startOffset: Int64
	/// What a commit advances to.
	let endOffset: Int64

	var span: Int64 {
		return endOffset - startOffset
	}

	/// The key a `tag.<tag>` rule is written under: lowercased with non-alphanumerics removed. Nil
	/// where nothing is left.
	static func normaliseTag(_ raw: String) -> String? {
		var out = ""
		for character in raw.lowercased() where character.isLetter || character.isNumber {
			out.append(character)
		}
		return out.isEmpty ? nil : out
	}
}

enum ReadStatus {
	case caughtUp
	case holdingPartial
	case moreAvailable
	case fileComplete
}

struct Frame {
	let status: ReadStatus
	/// Kept only.
	let records: [Record]
	/// The cursor this frame was read from; a commit targets this rather than whatever the reader
	/// has moved on to by then.
	let cursor: Cursor
	/// The next file's inode where the reader observed one by the end of this read.
	let successor: FileId?
	/// Renders as `cursor_from`.
	let startOffset: Int64
	/// Renders as `cursor_to`, and what a commit advances to.
	let endOffset: Int64
	/// The offset in force at endOffset, after every EXTRACTED record is accounted for and so
	/// unaffected by the filter.
	let declaredTimezone: String
	/// Sum of kept record spans; what softLimit bounds.
	let payloadSize: Int64
	/// Everything traversed, filtered and orphaned included.
	let consumedSize: Int64
	let filteredCount: Int64
	/// Destroyed by rotation before we read them.
	let lostBytes: Int64
	/// The first record this frame traversed, kept or filtered. The meta record is timestamped at
	/// it. Nil where the frame traversed none.
	let firstLocalTime: String?
	let firstTimezone: String?
}
