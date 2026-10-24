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

import Compression
import Foundation

/// The outbox stores bodies gzipped and the dispatcher sets `Content-Encoding` itself, so the HTTP
/// stack must not re-encode them.
enum Gzip {
	private static let headerSize = 10
	private static let trailerSize = 8

	static func compress(_ data: Data) -> Data? {
		guard !data.isEmpty else { return nil }
		let capacity = data.count + data.count / 2 + 1024
		var deflated = [UInt8](repeating: 0, count: capacity)
		let written: Int = data.withUnsafeBytes { source in
			guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
			return deflated.withUnsafeMutableBufferPointer { destination in
				compression_encode_buffer(destination.baseAddress!, capacity, base, data.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written > 0 else { return nil }

		var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
		out.append(contentsOf: deflated[0..<written])
		out.append(littleEndian: crc32(data))
		out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
		return out
	}

	static func decompress(_ data: Data) -> Data? {
		guard data.count > headerSize + trailerSize, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
			return nil
		}
		let trailer = data.suffix(trailerSize)
		var size: UInt32 = 0
		for (index, byte) in trailer.suffix(4).enumerated() {
			size |= UInt32(byte) << (8 * UInt32(index))
		}
		let capacity = size == 0 ? data.count * 8 : Int(size)
		let deflated = data.dropFirst(headerSize).dropLast(trailerSize)
		var out = [UInt8](repeating: 0, count: capacity)
		let written: Int = deflated.withUnsafeBytes { source in
			guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
			return out.withUnsafeMutableBufferPointer { destination in
				compression_decode_buffer(destination.baseAddress!, capacity, base, deflated.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written > 0 else { return nil }
		return Data(out[0..<written])
	}

	private static let crcTable: [UInt32] = {
		return (0..<256).map { index -> UInt32 in
			var value = UInt32(index)
			for _ in 0..<8 {
				value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
			}
			return value
		}
	}()

	static func crc32(_ data: Data) -> UInt32 {
		var crc: UInt32 = 0xFFFFFFFF
		for byte in data {
			crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
		}
		return crc ^ 0xFFFFFFFF
	}
}

private extension Data {
	mutating func append(littleEndian value: UInt32) {
		append(contentsOf: [
			UInt8(truncatingIfNeeded: value),
			UInt8(truncatingIfNeeded: value >> 8),
			UInt8(truncatingIfNeeded: value >> 16),
			UInt8(truncatingIfNeeded: value >> 24)
		])
	}
}
