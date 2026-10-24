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

/// A persisted position in ONE file. `successor` is a forward pointer, not a second position.
final class Cursor {
	/// The name of this cursor's own document.
	let id: String
	let file: FileId

	/// Read position.
	var offset: Int64
	/// Last DURABLY CAPTURED byte: delivered or sitting in the outbox. NOT "acknowledged".
	private(set) var committedOffset: Int64
	/// The next file's inode, once one is observed.
	private(set) var successor: FileId?
	/// The committed offset was reached by taking a record against a window end rather than against
	/// a following header.
	private(set) var chased: Bool
	/// The offset in force at the committed offset, written with it so the two cannot disagree.
	private(set) var declaredTimezone: String

	private let url: URL

	init(file: FileId, directory: URL, offset: Int64 = 0, committed: Int64 = 0,
		 successor: FileId? = nil, chased: Bool = false, declaredTimezone: String) {
		self.id = file.documentName
		self.file = file
		self.url = directory.appendingPathComponent(file.documentName)
		self.offset = offset
		self.committedOffset = committed
		self.successor = successor
		self.chased = chased
		self.declaredTimezone = declaredTimezone
	}

	/// Derived: a successor exists and the COMMITTED offset is at EOF. Only this permits the reader
	/// to move on. EOF is a fact about the file rather than about the document, so it is supplied.
	func isComplete(fileSize: Int64) -> Bool {
		return successor != nil && committedOffset >= fileSize
	}

	/// One durable write.
	func commit(offset: Int64, successor: FileId?, chased: Bool, declaredTimezone: String) {
		self.offset = Swift.max(self.offset, offset)
		self.committedOffset = offset
		if let successor = successor {
			self.successor = successor
		}
		self.chased = chased
		self.declaredTimezone = declaredTimezone
		persist()
	}

	/// Records a successor observed without advancing the position.
	func observe(successor: FileId?) {
		guard let successor = successor, successor != self.successor else { return }
		self.successor = successor
		persist()
	}

	func persist() {
		let document = CursorDocument(
			file: file.description,
			offset: offset,
			committed: committedOffset,
			successor: successor?.description,
			chased: chased,
			declaredTimezone: declaredTimezone
		)
		guard let data = try? JSONEncoder().encode(document) else { return }
		try? DurableFile.write(data, to: url)
		DurableFile.excludeFromBackup(url)
	}

	func delete() {
		try? FileManager.default.removeItem(at: url)
	}

	static func load(file: FileId, directory: URL) -> Cursor? {
		let url = directory.appendingPathComponent(file.documentName)
		guard let data = try? Data(contentsOf: url),
			  let document = try? JSONDecoder().decode(CursorDocument.self, from: data),
			  document.file == file.description else {
			return nil
		}
		return Cursor(
			file: file,
			directory: directory,
			offset: document.offset,
			committed: document.committed,
			successor: document.successor.flatMap { FileId(rendered: $0) },
			chased: document.chased,
			declaredTimezone: document.declaredTimezone
		)
	}

	/// Every cursor document in `directory`, whatever file it tracks.
	static func documentNames(in directory: URL) -> [String] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names.filter { $0.hasPrefix("cursor-") && $0.hasSuffix(".json") }
	}
}

/// Every field is always present, null where it is not currently meaningful. `complete` is not
/// stored: it follows from `successor` being set and `committed` standing at EOF.
struct CursorDocument: Codable {
	let file: String
	let offset: Int64
	let committed: Int64
	let successor: String?
	let chased: Bool
	let declaredTimezone: String

	enum CodingKeys: String, CodingKey {
		case file, offset, committed, successor, chased, declaredTimezone
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(file, forKey: .file)
		try container.encode(offset, forKey: .offset)
		try container.encode(committed, forKey: .committed)
		try container.encode(successor, forKey: .successor)
		try container.encode(chased, forKey: .chased)
		try container.encode(declaredTimezone, forKey: .declaredTimezone)
	}
}
