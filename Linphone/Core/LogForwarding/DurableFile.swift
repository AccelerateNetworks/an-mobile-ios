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

/// Write to a temporary name, fsync, rename into place, fsync the parent. A crash leaves the
/// previous content or the new, never half of either.
enum DurableFile {
	static func write(_ data: Data, to url: URL) throws {
		let directory = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
		try data.write(to: temp)
		try sync(file: temp)
		guard rename(temp.path, url.path) == 0 else {
			try? FileManager.default.removeItem(at: temp)
			throw CocoaError(.fileWriteUnknown)
		}
		sync(directory: directory)
	}

	static func sync(file url: URL) throws {
		let handle = open(url.path, O_RDONLY)
		guard handle >= 0 else { throw CocoaError(.fileWriteUnknown) }
		defer { close(handle) }
		guard fsync(handle) == 0 else { throw CocoaError(.fileWriteUnknown) }
	}

	static func sync(directory url: URL) {
		let handle = open(url.path, O_RDONLY)
		guard handle >= 0 else { return }
		fsync(handle)
		close(handle)
	}

	/// A restore would otherwise resurrect a stale offset against a different device's log file.
	static func excludeFromBackup(_ url: URL) {
		var target = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? target.setResourceValues(values)
	}
}
