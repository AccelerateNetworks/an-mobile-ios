/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of Linphone
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
import SwiftUI
import UIKit

extension Color {

	private static var theme: Theme { ColorProvider.shared.theme }

	static let transparentColor = Color(hex: "#00000000")
	static let black = Color(hex: "#000000")
	static let white = Color(hex: "#FFFFFF")

	static var orangeMain500: Color { theme.main500 }

	// Pale accent tint used for highlight backgrounds. In dark mode a light pastel
	// reads as a glaring patch, so it's swapped for a translucent wash of the accent instead.
	static var orangeMain100: Color {
		Color(UIColor { traits in
			if traits.userInterfaceStyle == .dark {
				return UIColor(theme.main500).withAlphaComponent(0.22)
			}
			return UIColor(theme.main100)
		})
	}

	static let grayMain2c800 = Color(light: "#22334D", dark: "#EAF0F5")
	static let grayMain2c800Alpha65 = Color(hex: "#A622334D")
	static let grayMain2c700 = Color(light: "#364860", dark: "#C7D2DB")
	static let grayMain2c600 = Color(light: "#4E6074", dark: "#B9C4CE")
	static let grayMain2c500 = Color(light: "#6C7A87", dark: "#96A3AD")
	static let grayMain2c400 = Color(light: "#9AABB5", dark: "#77858D")
	static let grayMain2c300 = Color(light: "#C0D1D9", dark: "#3A4750")
	static let grayMain2c200 = Color(light: "#DFECF2", dark: "#1C2830")
	static let grayMain2c100 = Color(light: "#EEF6F8", dark: "#10161B")

	static let gray100 = Color(light: "#F9F9F9", dark: "#121212")
	static let gray200 = Color(light: "#EDEDED", dark: "#1E1E1E")
	static let gray300 = Color(light: "#C9C9C9", dark: "#3D3D3D")
	static let gray400 = Color(light: "#949494", dark: "#8E8E93")
	static let gray500 = Color(light: "#4E4E4E", dark: "#B3B3B3")

	// Fixed (non-adaptive): the call UI keeps a permanently dark backdrop regardless
	// of system appearance, so these aren't part of the light/dark ramp.
	static let gray600 = Color(hex: "#2E3030")
	static let gray900 = Color(hex: "#070707")

	// Elevated card/row/pill surface that sits above the page background (gray100/200).
	static let cardBackground = Color(light: "#FFFFFF", dark: "#1C1C1E")

	static let redDanger200 = Color(hex: "#F5CCBE")
	static let redDanger500 = Color(hex: "#DD5F5F")
	static let redDanger700 = Color(hex: "#9E3548")

	static let greenSuccess500 = Color(hex: "#4FAE80")
	static let greenSuccess700 = Color(hex: "#377D71")
	static let greenSuccess200 = Color(hex: "#ACF5C1")

	static let blueInfo500 = Color(hex: "#4AA8FF")

	static let orangeWarning600 = Color(hex: "#DBB820")

	static let orangeAway = Color(hex: "#FFA645")

	/// A color that resolves to `light` or `dark` depending on the current system appearance.
	init(light: String, dark: String) {
		self.init(UIColor { traits in
			traits.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light))
		})
	}

	init(hex: String) {
		let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
		var int: UInt64 = 0
		Scanner(string: hex).scanHexInt64(&int)
		let alpha, red, green, blue: UInt64
		switch hex.count {
		case 3: // RGB (12-bit)
			(alpha, red, green, blue) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
		case 6: // RGB (24-bit)
			(alpha, red, green, blue) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
		case 8: // ARGB (32-bit)
			(alpha, red, green, blue) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
		default:
			(alpha, red, green, blue) = (1, 1, 1, 0)
		}
		
		self.init(
			.sRGB,
			red: Double(red) / 255,
			green: Double(green) / 255,
			blue: Double(blue) / 255,
			opacity: Double(alpha) / 255
		)
	}
}
