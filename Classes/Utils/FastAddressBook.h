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

#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>

#include "linphone/linphonecore.h"
#include "Contact.h"

@interface FastAddressBook : NSObject

@property(readonly, nonatomic) NSMutableDictionary *addressBookMap;
@property BOOL needToUpdate;

- (void)fetchContactsInBackGroundThread;
- (BOOL)deleteContact:(Contact *)contact;
- (BOOL)deleteCNContact:(CNContact *)CNContact;
- (BOOL)deleteAllContacts;
- (BOOL)saveContact:(Contact *)contact;
- (BOOL)saveCNContact:(CNContact *)CNContact contact:(Contact *)Contact;
- (void)reloadFriends;
- (void)clearFriends;

- (void)dumpContactsDisplayNamesToUserDefaults;
- (void)removeContactFromUserDefaults:(Contact *)contact;

+ (BOOL)isAuthorized;

// TOOLS

+ (Contact *)getContactWithAddress:(const LinphoneAddress *)address;
- (CNContact *)getCNContactFromContact:(Contact *)acontact;

+ (UIImage *)imageForContact:(Contact *)contact;
+ (UIImage *)imageForAddress:(const LinphoneAddress *)addr;
+ (UIImage *)imageForSecurityLevel:(LinphoneChatRoomSecurityLevel)level;

+ (BOOL)contactHasValidSipDomain:(Contact *)person;
+ (BOOL)isSipURIValid:(NSString*)addr;

+ (NSString *)displayNameForContact:(Contact *)person;
+ (NSString *)displayNameForAddress:(const LinphoneAddress *)addr;

+ (BOOL)isSipURI:(NSString *)address;
+ (BOOL)isSipAddress:(CNLabeledValue<CNInstantMessageAddress *> *)sipAddr;
+ (NSString *)normalizeSipURI:(NSString *)address use_prefix:(BOOL)use_prefix;

+ (NSString *)localizedLabel:(NSString *)label;
- (void)registerAddrsFor:(Contact *)contact;

@end
