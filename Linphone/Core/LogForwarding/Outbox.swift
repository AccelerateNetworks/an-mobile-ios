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

/// Makes request bodies durable. A stored body is the request body and nothing else.
final class Outbox {
	private static let tempPrefix = "temp-"

	let root: URL

	init(root: URL) {
		self.root = root
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		DurableFile.excludeFromBackup(root)
	}

	/// Each body is gzipped into `temp-<frame-id>/` and fsynced, then that directory is renamed to
	/// the frame id and the parent fsynced: the whole set appears at once, durable before the cursor
	/// commits. An existing `<frame-id>/` is deleted first, never merged.
	@discardableResult
	func write(frameId: String, bodies: [String]) throws -> URL {
		let staging = root.appendingPathComponent(Outbox.tempPrefix + frameId)
		let final = root.appendingPathComponent(frameId)
		try? FileManager.default.removeItem(at: staging)
		try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
		try store(bodies: bodies.map { Data($0.utf8) }, in: staging)
		try promote(staging: staging, to: final)
		return final
	}

	/// 413 only: decompress, halve logRecords, keep Resource. A single-record body cannot split.
	func split(_ body: URL) -> URL? {
		let parent = body.deletingPathExtension().lastPathComponent
		guard let stored = try? Data(contentsOf: body),
			  let raw = Gzip.decompress(stored),
			  let halves = Outbox.halve(raw) else {
			drop(body)
			return nil
		}
		let staging = root.appendingPathComponent(Outbox.tempPrefix + "split-" + parent)
		let final = root.appendingPathComponent("split-" + parent)
		try? FileManager.default.removeItem(at: staging)
		guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil,
			  (try? store(bodies: halves, in: staging)) != nil,
			  (try? promote(staging: staging, to: final)) != nil else {
			try? FileManager.default.removeItem(at: staging)
			return nil
		}
		drop(body)
		return final
	}

	/// Unordered; every directory without the temp- prefix.
	func pending() -> [URL] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		return names
			.filter { !$0.hasPrefix(Outbox.tempPrefix) && !$0.hasPrefix(".") }
			.map { root.appendingPathComponent($0) }
			.filter { isDirectory($0) }
	}

	func bodies(in directory: URL) -> [URL] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names.filter { $0.hasSuffix(".gz") }.map { directory.appendingPathComponent($0) }
	}

	/// Deletes every temp- directory, at run start where no write can be in progress.
	func sweep() {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		for name in names where name.hasPrefix(Outbox.tempPrefix) {
			try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
		}
	}

	/// Deletes every directory, temp- or not. The policy that calls it is the forwarder's.
	func clear() {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		for name in names {
			try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
		}
	}

	/// One body, on any terminal outcome; takes the directory with its last body. Idempotent.
	func drop(_ body: URL) {
		try? FileManager.default.removeItem(at: body)
		let directory = body.deletingLastPathComponent()
		guard directory != root, bodies(in: directory).isEmpty else { return }
		try? FileManager.default.removeItem(at: directory)
	}

	/// Bodies are addressed by identity, so a rename cannot lose one.
	func find(id: FileId) -> URL? {
		for directory in pending() {
			for body in bodies(in: directory) where InodeUtils.idOf(path: body.path) == id {
				return body
			}
		}
		return nil
	}

	// MARK: - Staging

	private func store(bodies: [Data], in staging: URL) throws {
		for body in bodies {
			guard let compressed = Gzip.compress(body) else { continue }
			let name = Outbox.contentHash(body) + ".gz"
			let url = staging.appendingPathComponent(name)
			try compressed.write(to: url)
			try DurableFile.sync(file: url)
		}
		DurableFile.sync(directory: staging)
	}

	private func promote(staging: URL, to final: URL) throws {
		try? FileManager.default.removeItem(at: final)
		guard rename(staging.path, final.path) == 0 else {
			throw CocoaError(.fileWriteUnknown)
		}
		DurableFile.sync(directory: root)
	}

	private func isDirectory(_ url: URL) -> Bool {
		var directory: ObjCBool = false
		let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
		return exists && directory.boolValue
	}

	/// Of the body as handed in, not of the gzip.
	static func contentHash(_ body: Data) -> String {
		return SHA256.hash(data: body).hex
	}

	/// Keeps Resource and halves the log records. Nil where there is nothing to halve.
	static func halve(_ body: Data) -> [Data]? {
		guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
			  var resourceLogs = root["resourceLogs"] as? [[String: Any]],
			  var scopeLogs = resourceLogs.first?["scopeLogs"] as? [[String: Any]],
			  let records = scopeLogs.first?["logRecords"] as? [[String: Any]],
			  records.count > 1 else {
			return nil
		}
		let middle = records.count / 2
		var halves: [Data] = []
		for slice in [Array(records[0..<middle]), Array(records[middle...])] {
			var scope = scopeLogs[0]
			scope["logRecords"] = slice
			scopeLogs[0] = scope
			var resource = resourceLogs[0]
			resource["scopeLogs"] = scopeLogs
			resourceLogs[0] = resource
			guard let data = try? JSONSerialization.data(withJSONObject: ["resourceLogs": resourceLogs]) else {
				return nil
			}
			halves.append(data)
		}
		return halves
	}
}
