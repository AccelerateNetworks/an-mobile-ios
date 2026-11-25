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
import linphonesw
import PhoneNumberKit

class LinphoneUtils: NSObject {
	static let RECORDING_FILE_NAME_HEADER = "call_recording_sip_"
	static let RECORDING_FILE_NAME_URI_TIMESTAMP_SEPARATOR = "_on_"
	static let RECORDING_MKV_FILE_EXTENSION = ".mkv"
	static let RECORDING_SMFF_FILE_EXTENSION = ".smff"
	
	public class func isChatRoomAGroup(chatRoom: ChatRoom) -> Bool {
		let oneToOne = chatRoom.hasCapability(mask: ChatRoom.Capabilities.OneToOne.rawValue)
		let conference = chatRoom.hasCapability(mask: ChatRoom.Capabilities.Conference.rawValue)
		return !oneToOne && conference
	}
	
	public class func getChatIconState(chatState: Int) -> String {
		return switch chatState {
		case ChatMessage.State.Displayed.rawValue, ChatMessage.State.FileTransferDone.rawValue:
			"checks"
		case ChatMessage.State.DeliveredToUser.rawValue:
			"check"
		case ChatMessage.State.Delivered.rawValue:
			"envelope-simple"
		case ChatMessage.State.NotDelivered.rawValue, ChatMessage.State.FileTransferError.rawValue:
			"warning-circle"
		case ChatMessage.State.InProgress.rawValue, ChatMessage.State.FileTransferInProgress.rawValue:
			"animated-in-progress"
		default:
			"animated-in-progress"
		}
	}
	
	public class func getChatRoomId(room: ChatRoom) -> String {
		return room.identifier ?? ""
		//return getChatRoomId(localAddress: room.localAddress!, remoteAddress: room.peerAddress!)
	}
	
	public class func getChatRoomId(localAddress: Address, remoteAddress: Address) -> String {
		let localSipUri = localAddress.clone()
		localSipUri!.clean()
		let remoteSipUri = remoteAddress.clone()
		remoteSipUri!.clean()
		return getChatRoomId(localSipUri: localSipUri!.asStringUriOnly(), remoteSipUri: remoteSipUri!.asStringUriOnly())
	}
	
	public class func getChatRoomId(localSipUri: String, remoteSipUri: String) -> String {
		return "\(localSipUri)#~#\(remoteSipUri)"
	}
	
	public class func applyInternationalPrefix(core: Core, account: Account? = nil) -> Bool {
		return	account?.params?.useInternationalPrefixForCallsAndChats == true 
		|| core.defaultAccount?.params?.useInternationalPrefixForCallsAndChats == true
	}

	private static let phoneNumberUtility = PhoneNumberUtility()

	/// Parses `number` in the account's country with libphonenumber's rules. Returns nil when the
	/// number isn't valid there, instead of trimming it to fit as liblinphone's dial plan does.
	public class func getE164(number: String, account: Account) -> String? {
		guard let parsed = try? phoneNumberUtility.parse(number, withRegion: getCountryIso(account: account), ignoreType: false) else {
			return nil
		}
		return phoneNumberUtility.format(parsed, toType: .e164)
	}

	private class func getCountryIso(account: Account) -> String {
		if let iso = account.params?.internationalPrefixIsoCountryCode, iso.count == 2 {
			return iso
		}
		let prefix = account.params?.internationalPrefix ?? ""
		if prefix.isEmpty || prefix == "1" {
			return "US"
		}
		return Factory.Instance.dialPlans.first(where: { $0.countryCallingCode == prefix })?.isoCountryCode ?? "US"
	}

	/// Use instead of Core.interpretUrl for typed and contact input. When liblinphone applies the
	/// international prefix it keeps only the last national-length digits, so a mistyped
	/// 42533383589 would become +12533383589. Here a valid number becomes E.164 and anything else
	/// is kept as typed. Must be called on the core queue.
	public class func interpretUrl(core: Core, url: String, account: Account? = nil) -> Address? {
		let applyPrefix = applyInternationalPrefix(core: core, account: account)
		guard applyPrefix, let account = account ?? getDefaultAccount(), account.isPhoneNumber(username: url) else {
			return core.interpretUrl(url: url, applyInternationalPrefix: applyPrefix)
		}
		return core.interpretUrl(url: getE164(number: url, account: account) ?? url, applyInternationalPrefix: false)
	}

	/// AN's messaging service delivers inbound texts from, and keys server-side threads on, a
	/// +1 number's E.164 form without the plus (14253338358). Other countries' numbers are
	/// returned unchanged. A 1-on-1 conversation must be both searched for and created with the
	/// address returned here, or it splits from its inbound half.
	/// Must be called on the core queue.
	public class func getChatPeerAddress(address: Address, account: Account? = nil) -> Address {
		guard let account = account ?? getDefaultAccount(),
			  account.params?.useInternationalPrefixForCallsAndChats == true,
			  let username = address.username,
			  address.domain?.caseInsensitiveCompare(account.params?.domain ?? "") == .orderedSame,
			  account.isPhoneNumber(username: username) else {
			return address
		}
		guard let e164 = getE164(number: username, account: account) else {
			Log.info("\(#function) [\(username)] isn't a valid number for the account's country, using it as typed for chat peer [\(address.asStringUriOnly())]")
			return address
		}
		guard e164.hasPrefix("+1"),
			  let peer = address.clone(),
			  (try? peer.setUsername(newValue: String(e164.dropFirst()))) != nil else {
			return address
		}
		Log.info("\(#function) Using [\(peer.asStringUriOnly())] as chat peer for [\(address.asStringUriOnly())]")
		return peer
	}
	
	public class func isEndToEndEncryptedChatAvailable(core: Core) -> Bool {
		return core.limeX3DhEnabled &&
		core.defaultAccount?.params?.limeServerUrl != nil &&
		core.defaultAccount?.params?.conferenceFactoryUri != nil
	}
	
	public class func createConferenceScheduler(core: Core) -> ConferenceScheduler? {
		let account = LinphoneUtils.getDefaultAccount()
		if let url = account?.params?.ccmpServerUrl, !url.isEmpty {
			Log.info(
				"CCMP server URL has been set in Account's params, using CCMP conference scheduler"
			)
			
			let conferenceScheduler = try? core.createConferenceSchedulerWithType(
				account: account,
				schedulingType: .CCMP
			)
				
			return conferenceScheduler
		}
		Log.info(
			"CCMP server URL hasn't been set in Account's params, using SIP conference scheduler"
		)
		
		let conferenceScheduler = try? core.createConferenceSchedulerWithType(
			account: account,
			schedulingType: .SIP
		)
		
		return conferenceScheduler
	}
	
	public class func createGroupCall(core: Core, account: Account?, subject: String) -> Conference? {
		do {
			let conferenceParams = try core.createConferenceParams(conference: nil)
			conferenceParams.videoEnabled = true
			conferenceParams.account = account
			conferenceParams.subject = subject
			
			// Enable end-to-end encryption if client supports it
			//if isEndToEndEncryptedChatAvailable(core: core) {
			if false {
				Log.info("\(#function) Requesting EndToEnd security level for conference")
				conferenceParams.securityLevel = .EndToEnd
			} else {
				Log.info("\(#function) Requesting PointToPoint security level for conference")
				conferenceParams.securityLevel = .PointToPoint
			}
			
			// Allows to have a chat room within the conference
			conferenceParams.chatEnabled = true
			
			Log.info("\(#function) Creating group call with subject \(conferenceParams.subject ?? "Unknown")")
			
			let confWithParams = try core.createConferenceWithParams(params: conferenceParams)
			
			return confWithParams
		} catch let error {
			Log.info("\(#function) Error while creating group call: \(error)")
			return nil
		}
	}
	
	public class func getConversationId(chatRoom: ChatRoom) -> String {
		return chatRoom.identifier ?? ""
		
	}
	
	public class func getDefaultAccount() -> Account? {
		return CoreContext.shared.mCore.defaultAccount ?? (CoreContext.shared.mCore.accountList.first ?? nil)
	}

	public class func getAddressAsCleanStringUriOnly(address: Address) -> String {
		guard let cleaned = address.clone() else {
			return address.asStringUriOnly()
		}
		cleaned.clean()
		return cleaned.asStringUriOnly()
	}

	public class func getDisplayAddress(address: Address) -> String {
		let username = address.username ?? ""
		if !AppServices.corePreferences.onlyDisplaySipUriUsername || username.isEmpty {
			return getAddressAsCleanStringUriOnly(address: address)
		}
		let homeDomain = getDefaultAccount()?.params?.domain
		if address.domain == homeDomain || address.domain == AppServices.corePreferences.defaultDomain {
			return username
		}
		return getAddressAsCleanStringUriOnly(address: address)
	}

	public class func getAccountForAddress(address: Address) -> Account? {
		return CoreContext.shared.mCore.accountList.first { $0.params?.identityAddress?.weakEqual(address2: address) == true }
	}
	
	public class func isRemoteConferencingAvailable(core: Core) -> Bool {
		return core.defaultAccount?.params?.audioVideoConferenceFactoryAddress != nil
	}
	
	public class func isGroupChatAvailable(core: Core) -> Bool {
		return core.defaultAccount?.params?.conferenceFactoryUri != nil
	}
}
