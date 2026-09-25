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

import XCTest
@testable import LinphoneApp

class RemoteProvisioningUrlTests: XCTestCase {

	private let provisioningUrl = "https://host.example/app/linphone/provision/index.php?token=abc"

	private func parse(_ input: String) -> String? {
		return LinphoneUtils.getRemoteProvisioningUrl(from: input)
	}

	func testPlainHttpsUrlIsUnchanged() {
		XCTAssertEqual(parse(provisioningUrl), provisioningUrl)
	}

	func testWhitespaceIsTrimmed() {
		XCTAssertEqual(parse("  \(provisioningUrl)\n"), provisioningUrl)
	}

	func testBareHostGetsHttps() {
		XCTAssertEqual(parse("host.example/app/linphone/provision/index.php?token=abc"), provisioningUrl)
	}

	func testConfigSchemeWithInnerHttpsUrl() {
		XCTAssertEqual(parse("linphone-config:\(provisioningUrl)"), provisioningUrl)
	}

	func testConfigSchemeWithAuthority() {
		XCTAssertEqual(parse("linphone-config://host.example/app/linphone/provision/index.php?token=abc"), provisioningUrl)
	}

	func testConfigSchemeWithoutSlashes() {
		XCTAssertEqual(parse("linphone-config:host.example/app/linphone/provision/index.php?token=abc"), provisioningUrl)
	}

	func testConfigSchemeWithSlashesAndInnerHttpsUrl() {
		XCTAssertEqual(parse("linphone-config://\(provisioningUrl)"), provisioningUrl)
	}

	func testConfigSchemeWithSlashesAndColonlessInnerScheme() {
		XCTAssertEqual(parse("linphone-config://https//host.example/app/linphone/provision/index.php?token=abc"), provisioningUrl)
	}

	func testConfigSchemeIsCaseInsensitive() {
		XCTAssertEqual(parse("LINPHONE-CONFIG://HTTPS://host.example/p"), "HTTPS://host.example/p")
	}

	func testConfigSchemeKeepsHttp() {
		XCTAssertEqual(parse("linphone-config:http://host.example/p"), "http://host.example/p")
	}

	func testConfigSchemeKeepsFileUrl() {
		XCTAssertEqual(parse("linphone-config:file:///var/mobile/config.xml"), "file:///var/mobile/config.xml")
	}

	func testUnsupportedSchemeIsRejected() {
		XCTAssertNil(parse("ftp://host.example/config.xml"))
		XCTAssertNil(parse("linphone-config:ftp://host.example/config.xml"))
	}

	func testEmptyInputIsRejected() {
		XCTAssertNil(parse(""))
		XCTAssertNil(parse("   "))
		XCTAssertNil(parse("linphone-config:"))
		XCTAssertNil(parse("linphone-config://"))
	}
}
