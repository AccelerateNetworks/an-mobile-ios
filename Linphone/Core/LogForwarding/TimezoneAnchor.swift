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

/// liblinphone formats the record header through `localtime()` and discards the offset, so the file
/// carries local wall clock with no zone. An anchor is an ordinary app-layer line stating the offset
/// in force when it was written, and applies forward from where it lands.
enum TimezoneAnchor {
	/// The offset in force on this device now, as a record declares it.
	static func currentOffset() -> String {
		let seconds = TimeZone.current.secondsFromGMT()
		let magnitude = abs(seconds)
		return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", magnitude / 3600, (magnitude % 3600) / 60)
	}

	/// Reaches the file whenever the process is alive: log collection is enabled through `Factory`
	/// rather than on a Core.
	static func write() {
		Log.info("[\(LogForwarding.forwarderTag)] tz anchor \(currentOffset())")
	}
}
