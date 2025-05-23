/*
 * Copyright (c) 2010-2020 Belledonne Communications SARL.
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

import UIKit
import DropDown

@objc(MyCell) class MyCell: DropDownCell {
	
	@IBOutlet var myImageView: UIImageView!
	@IBOutlet var myEmojisView: UIView!
	@IBOutlet var myEmojiButton1: UIButton!
	@IBOutlet var myEmojiButton2: UIButton!
	@IBOutlet var myEmojiButton3: UIButton!
	@IBOutlet var myEmojiButton4: UIButton!
	@IBOutlet var myEmojiButton5: UIButton!

    override func awakeFromNib() {
        super.awakeFromNib()
		myImageView.contentMode = .scaleAspectFit
		myEmojisView.isHidden = true
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
}
