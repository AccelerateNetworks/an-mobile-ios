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

/// Ordered by increasing verbosity. A threshold admits a record at or below it, so `warning` admits
/// warning, error and fatal. A record carries one of the five real levels; `none` is a threshold only.
enum Level: Int, Comparable, Codable {
	case none = 0
	case fatal = 1
	case error = 2
	case warning = 3
	case message = 4
	case debug = 5

	static func < (lhs: Level, rhs: Level) -> Bool {
		return lhs.rawValue < rhs.rawValue
	}

	/// A provisioned threshold token, any of the six. Nil for anything else, `trace` included.
	static func threshold(_ token: String) -> Level? {
		switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "none": return Level.none
		case "fatal": return .fatal
		case "error": return .error
		case "warning": return .warning
		case "message": return .message
		case "debug": return .debug
		default: return nil
		}
	}

	/// The token a record header carries. Never `none`.
	static func recordToken(_ token: String) -> Level? {
		switch token {
		case "FATAL": return .fatal
		case "ERROR": return .error
		case "WARNING": return .warning
		case "MESSAGE": return .message
		case "DEBUG": return .debug
		default: return nil
		}
	}

	/// The device's own token, not OTLP's name for the band.
	var severityText: String {
		switch self {
		case .none: return "NONE"
		case .fatal: return "FATAL"
		case .error: return "ERROR"
		case .warning: return "WARNING"
		case .message: return "MESSAGE"
		case .debug: return "DEBUG"
		}
	}

	var severityNumber: Int {
		switch self {
		case .none: return 0
		case .fatal: return 21
		case .error: return 17
		case .warning: return 13
		case .message: return 9
		case .debug: return 5
		}
	}

	var configToken: String {
		switch self {
		case .none: return "none"
		case .fatal: return "fatal"
		case .error: return "error"
		case .warning: return "warning"
		case .message: return "message"
		case .debug: return "debug"
		}
	}
}
