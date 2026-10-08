/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
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

/// Remote provisioning URL grammar shared with an-mobile-android (ProvisioningUrl.kt).
///
/// liblinphone compares the scheme case-sensitively, so it must be lowercased here;
/// the rest of the URL is left alone because provisioning tokens are case-sensitive.
enum ProvisioningUrl {
	static let configSchemePrefix = "linphone-config:"

	static func isConfigUri(_ uri: String) -> Bool {
		return hasConfigPrefix(uri.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	static func normalize(_ uri: String) -> String {
		var url = uri.trimmingCharacters(in: .whitespacesAndNewlines)
		if hasConfigPrefix(url) {
			url = String(url.dropFirst(configSchemePrefix.count))
		}
		if url.hasPrefix("//") {
			url = "https:" + url
		}
		if let schemeEnd = url.range(of: "://"), schemeEnd.lowerBound > url.startIndex {
			url = url[..<schemeEnd.lowerBound].lowercased() + url[schemeEnd.lowerBound...]
		}
		return url
	}

	static func isValid(_ url: String) -> Bool {
		// A bare scheme (e.g. from "linphone-config://") has nothing to fetch
		return ["https://", "file://"].contains { url.hasPrefix($0) && url.count > $0.count }
	}

	/// Returns the normalised URL, or nil if it isn't an acceptable provisioning URL.
	static func parse(_ uri: String) -> String? {
		let url = normalize(uri)
		return isValid(url) ? url : nil
	}

	/// Maps the message liblinphone passes along with ConfiguringState.Failed to a ToastView key.
	static func failureToast(for message: String) -> String {
		switch message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "":
			return "Failed_uri_handler_config_failed"
		case "bad uri":
			return "Failed_remote_provisioning_bad_uri"
		case "http error", "http io error":
			return "Failed_remote_provisioning_network"
		case "http timeout":
			return "Failed_remote_provisioning_timeout"
		case "http auth requested":
			return "Failed_remote_provisioning_auth"
		default:
			// Anything else is the XML parser's error text
			return "Failed_remote_provisioning_invalid_config"
		}
	}

	private static func hasConfigPrefix(_ uri: String) -> Bool {
		return uri.lowercased().hasPrefix(configSchemePrefix)
	}
}
