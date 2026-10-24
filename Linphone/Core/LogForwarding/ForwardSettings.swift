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
import linphonesw

/// The forward thresholds. Most specific wins: a tag rule beats a subsystem rule beats `default`.
struct ForwardSettings: Equatable {
	let `default`: Level
	let levels: [String: Level]
	let tags: [String: Level]

	init(default defaultLevel: Level = .warning, levels: [String: Level] = [:], tags: [String: Level] = [:]) {
		self.default = defaultLevel
		self.levels = levels
		self.tags = tags
	}

	func levelFor(subsystem: String) -> Level {
		return levels[subsystem] ?? self.default
	}

	/// Nil when there is no rule for this tag.
	func levelForTag(_ tag: String?) -> Level? {
		guard let tag = tag else { return nil }
		return tags[tag]
	}

	func thresholdFor(_ record: Record) -> Level {
		return levelForTag(record.tag) ?? levelFor(subsystem: record.subsystem)
	}

	func accepts(_ record: Record) -> Bool {
		return record.level <= thresholdFor(record)
	}

	/// Does `next` admit anything these settings did not? Answers conservatively where a tag rule on
	/// one side falls through to a subsystem threshold on the other, because an unnecessary replay
	/// costs re-sent records and a missed one costs the records the escalation was asked for.
	func requiresReplay(_ next: ForwardSettings) -> Bool {
		if next.default > self.default {
			return true
		}
		var subsystems = Set(levels.keys)
		subsystems.formUnion(next.levels.keys)
		for subsystem in subsystems where next.levelFor(subsystem: subsystem) > levelFor(subsystem: subsystem) {
			return true
		}
		var tagKeys = Set(tags.keys)
		tagKeys.formUnion(next.tags.keys)
		let oldWeakest = lowestSubsystemThreshold
		let newStrongest = next.highestSubsystemThreshold
		for key in tagKeys {
			switch (tags[key], next.tags[key]) {
			case (nil, nil):
				continue
			case let (.some(old), .some(new)):
				if new > old { return true }
			case let (nil, .some(new)):
				if new > oldWeakest { return true }
			case let (.some(old), nil):
				if newStrongest > old { return true }
			}
		}
		return false
	}

	private var lowestSubsystemThreshold: Level {
		return levels.values.reduce(self.default) { Swift.min($0, $1) }
	}

	private var highestSubsystemThreshold: Level {
		return levels.values.reduce(self.default) { Swift.max($0, $1) }
	}

	/// Terms in lexicographical order by key: `Dictionary` iteration order is randomised per process.
	var sha256: Data {
		var lines = ["default=\(self.default.configToken)"]
		for key in levels.keys.sorted() {
			lines.append("level.\(key)=\(levels[key]!.configToken)")
		}
		for key in tags.keys.sorted() {
			lines.append("tag.\(key)=\(tags[key]!.configToken)")
		}
		return Data(SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)))
	}
}

/// Everything `[log_forwarding]` carries. Read from a `Config`, never from a `Core`.
struct ForwarderConfig {
	static let section = "log_forwarding"

	private static let defaultSoftLimit: Int64 = 262144
	private static let defaultMaxPostBytes = 1048576
	private static let defaultForegroundInterval: Int64 = 10000
	private static let defaultBackgroundInterval: Int64 = 86400000
	private static let defaultMaxBackoff: Int64 = 900000

	let url: String
	let settings: ForwardSettings
	/// Raw record bytes KEPT per read. -1 means unbounded.
	let softLimit: Int64
	/// Rendered bytes per export, before gzip.
	let maxPostBytes: Int
	let foregroundInterval: TimeInterval
	let backgroundInterval: TimeInterval
	let maxBackoff: TimeInterval

	static func load(from config: Config) -> ForwarderConfig {
		let section = ForwarderConfig.section
		let url = config.getString(section: section, key: "url", defaultString: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let defaultLevel = Level.threshold(config.getString(section: section, key: "default_level", defaultString: "warning")) ?? .warning

		var levels: [String: Level] = [:]
		var tags: [String: Level] = [:]
		for key in config.getKeysNamesList(section: section) {
			if key.hasPrefix("level.") {
				let subsystem = String(key.dropFirst("level.".count))
				if !subsystem.isEmpty, let level = Level.threshold(config.getString(section: section, key: key, defaultString: "")) {
					levels[subsystem] = level
				}
			} else if key.hasPrefix("tag.") {
				let tag = String(key.dropFirst("tag.".count))
				if !tag.isEmpty, let level = Level.threshold(config.getString(section: section, key: key, defaultString: "")) {
					tags[Record.normaliseTag(tag) ?? tag] = level
				}
			}
		}

		let softLimit = config.getLong("soft_limit", defaultSoftLimit, min: 1, specials: [-1])
		let maxPostBytes = config.getInt("max_post_bytes", defaultMaxPostBytes, min: 1)
		let foreground = config.getLong("foreground_interval", defaultForegroundInterval, min: 100)
		let background = config.getLong("background_interval", defaultBackgroundInterval, min: 1)
		let maxBackoff = config.getLong("max_backoff", defaultMaxBackoff, min: 1)

		return ForwarderConfig(
			url: url,
			settings: ForwardSettings(default: defaultLevel, levels: levels, tags: tags),
			softLimit: softLimit,
			maxPostBytes: maxPostBytes,
			foregroundInterval: Double(foreground) / 1000.0,
			backgroundInterval: Double(background) / 1000.0,
			maxBackoff: Double(maxBackoff) / 1000.0
		)
	}

	/// Rides the meta record, and changes on reprovision.
	struct AccountIdentity {
		let tenant: String
		let `extension`: String
	}

	/// `sip/default_proxy` into `proxy_<n>/reg_identity`, which is `sip:<extension>@<tenant>`.
	static func identity(from config: Config) -> AccountIdentity {
		let index = config.getInt(section: "sip", key: "default_proxy", defaultValue: 0)
		let identity = config.getString(section: "proxy_\(index)", key: "reg_identity", defaultString: "")
		guard let at = identity.lastIndex(of: "@") else {
			return AccountIdentity(tenant: "", extension: "")
		}
		var user = String(identity[identity.startIndex..<at])
		if let colon = user.firstIndex(of: ":") {
			user = String(user[user.index(after: colon)...])
		}
		var host = String(identity[identity.index(after: at)...])
		if let cut = host.firstIndex(where: { $0 == ":" || $0 == ";" || $0 == ">" }) {
			host = String(host[host.startIndex..<cut])
		}
		return AccountIdentity(tenant: host, extension: user)
	}
}

private extension Config {
	/// `getInt` yields 0 for a key present but blank or unparsable, so parse the string instead. A
	/// value outside `min...max` and not among `specials` means `defaultValue`.
	func getLong(_ key: String, _ defaultValue: Int64,
				 min: Int64 = .min, max: Int64 = .max, specials: [Int64] = []) -> Int64 {
		let section = ForwarderConfig.section
		let raw = getString(section: section, key: key, defaultString: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if raw.isEmpty {
			if getKeysNamesList(section: section).contains(key) {
				Log.warn("[config] \"\(key)\" is provisioned blank, using '\(defaultValue)'")
			}
			return defaultValue
		}
		guard let value = Int64(raw) else {
			Log.warn("[config] \"\(key)\" '\(raw)' is not a number, using '\(defaultValue)'")
			return defaultValue
		}
		if specials.contains(value) { return value }
		if value < min || value > max {
			Log.warn("[config] \"\(key)\" '\(value)' is out of range, using '\(defaultValue)'")
			return defaultValue
		}
		return value
	}

	/// Bounds to the `Int` range so the narrowing cannot overflow. Redundant where `Int` is 64-bit.
	func getInt(_ key: String, _ defaultValue: Int,
				min: Int = .min, max: Int = .max, specials: [Int] = []) -> Int {
		return Int(getLong(key, Int64(defaultValue), min: Int64(min), max: Int64(max),
						   specials: specials.map(Int64.init)))
	}
}
