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

#import <UIKit/UIKit.h>
#include "linphone/linphonecore.h"

#import <AddressBook/AddressBook.h>
#import "UICompositeView.h"
#import "HistoryDetailsTableView.h"
#import "UIRoundedImageView.h"

@interface HistoryDetailsView : TPMultiLayoutViewController <UICompositeViewDelegate> {
  @private
	LinphoneCallLog *callLog;
}
@property(weak, nonatomic) IBOutlet UIButton *backButton;
@property(weak, nonatomic) IBOutlet UILabel *contactLabel;
@property(nonatomic, strong) IBOutlet UIRoundedImageView *avatarImage;
@property(nonatomic, strong) IBOutlet UILabel *addressLabel;
@property(nonatomic, strong) IBOutlet UIButton *addContactButton;
@property(nonatomic, copy, setter=setCallLogId:) NSString *callLogId;
@property(weak, nonatomic) IBOutlet UIView *headerView;
@property(strong, nonatomic) IBOutlet HistoryDetailsTableView *tableView;
@property(weak, nonatomic) IBOutlet UILabel *emptyLabel;
@property (weak, nonatomic) IBOutlet UIView *waitView;
@property (weak, nonatomic) IBOutlet UIRoundedImageView *linphoneImage;
@property (weak, nonatomic) IBOutlet UIView *optionsView;
@property(weak, nonatomic) IBOutlet UIButton *chatButton;
@property (weak, nonatomic) IBOutlet UIView *encryptedChatView;

- (IBAction)onBackClick:(id)event;
- (IBAction)onAddContactClick:(id)event;
- (IBAction)onCallClick:(id)event;
- (IBAction)onChatClick:(id)event;
- (IBAction)onEncryptedChatClick:(id)sender;
- (void)setCallLogId:(NSString *)acallLogId;

@end
