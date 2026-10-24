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

/// An open file descriptor. Rotation cannot change what it points at.
typealias Handle = Int32

/// Opaque, platform-sourced. Equality and rendering only: never parsed, never compared across
/// platforms.
struct FileId: Equatable, Hashable, CustomStringConvertible {
	let device: UInt64
	let inode: UInt64

	/// Renders as `cursor_file`.
	var description: String {
		return "(dev=\(device),ino=\(inode))"
	}

	/// Filename-safe form, for naming a cursor document.
	var documentName: String {
		return "cursor-\(device)-\(inode).json"
	}

	/// Reconstructs one from the form `description` wrote. Reading a persisted document is the only
	/// caller.
	init?(rendered: String) {
		guard rendered.hasPrefix("(dev="), rendered.hasSuffix(")") else { return nil }
		let body = rendered.dropFirst("(dev=".count).dropLast()
		let parts = body.components(separatedBy: ",ino=")
		guard parts.count == 2, let device = UInt64(parts[0]), let inode = UInt64(parts[1]) else { return nil }
		self.device = device
		self.inode = inode
	}

	init(device: UInt64, inode: UInt64) {
		self.device = device
		self.inode = inode
	}
}

/// File APIs address by path; this design addresses by identity, because rotation renames files out
/// from under a path.
enum InodeUtils {
	/// Nil when the path does not exist.
	static func idOf(path: String) -> FileId? {
		var info = stat()
		guard stat(path, &info) == 0 else { return nil }
		return FileId(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
	}

	/// Of an OPEN descriptor, which rotation cannot change.
	static func idOf(handle: Handle) -> FileId? {
		var info = stat()
		guard fstat(handle, &info) == 0 else { return nil }
		return FileId(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
	}

	static func size(handle: Handle) -> Int64 {
		var info = stat()
		guard fstat(handle, &info) == 0 else { return 0 }
		return Int64(info.st_size)
	}

	/// `1.log` is always older than `2.log`, so the index is the age ordering.
	static func paths(dir: String, prefix: String) -> [String] {
		return ["\(dir)/\(prefix)1.log", "\(dir)/\(prefix)2.log"]
	}

	/// The path currently holding `id`, or nil if it is gone.
	static func find(dir: String, prefix: String, id: FileId) -> String? {
		return paths(dir: dir, prefix: prefix).first { idOf(path: $0) == id }
	}

	/// Find, open, then verify the descriptor is the file asked for, retrying on a rotation that
	/// landed between the two. Nil once it is gone.
	static func openById(dir: String, prefix: String, id: FileId) -> Handle? {
		for _ in 0..<4 {
			guard let path = find(dir: dir, prefix: prefix, id: id) else { return nil }
			let handle = open(path, O_RDONLY)
			if handle < 0 { continue }
			if idOf(handle: handle) == id { return handle }
			close(handle)
		}
		return nil
	}

	static func openPath(_ path: String) -> Handle? {
		let handle = open(path, O_RDONLY)
		return handle < 0 ? nil : handle
	}

	/// Reads at an absolute offset, so the descriptor carries no position of its own.
	static func read(handle: Handle, at offset: Int64, count: Int) -> [UInt8] {
		guard count > 0 else { return [] }
		var buffer = [UInt8](repeating: 0, count: count)
		let read: Int = buffer.withUnsafeMutableBytes { raw in
			guard let base = raw.baseAddress else { return 0 }
			return pread(handle, base, count, off_t(offset))
		}
		if read <= 0 { return [] }
		if read < count { buffer.removeSubrange(read..<count) }
		return buffer
	}
}
