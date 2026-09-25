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

	// AccelerateNetworks: iOS counterpart of Android's LinphoneUtils.getRemoteProvisioningUrlFromUri,
	// shared by the linphone-config: URI handler and the assistant's login-with-URL field.
	/// Turns a provisioning link into the URL to hand to `core.provisioningUri`, or nil when it isn't one.
	/// Accepts `linphone-config:https://host/...`, `linphone-config://host/...`, `linphone-config://https://host/...`,
	/// `linphone-config:file://...`, a plain http(s) URL and a bare host, all case-insensitively.
	public class func getRemoteProvisioningUrl(from input: String) -> String? {
		var urlString = input.trimmingCharacters(in: .whitespacesAndNewlines)

		let configScheme = "linphone-config:"
		if urlString.lowercased().hasPrefix(configScheme) {
			urlString = String(urlString.dropFirst(configScheme.count))
			if urlString.hasPrefix("//") {
				urlString = String(urlString.dropFirst(2))
			}
		}

		// linphone-config://https://host parses with "https" as the host and an empty port, which
		// can come back canonicalised to linphone-config://https//host: put the colon back.
		if let range = urlString.range(of: "^https?//", options: [.regularExpression, .caseInsensitive]) {
			urlString.insert(":", at: urlString.index(before: urlString.index(before: range.upperBound)))
		}

		if let schemeRange = urlString.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) {
			let scheme = urlString[schemeRange].dropLast(3).lowercased()
			guard ["http", "https", "file"].contains(scheme) else {
				return nil
			}
		} else {
			urlString = "https://" + urlString
		}

		guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
			return nil
		}
		if scheme == "file" {
			return url.path.isEmpty ? nil : urlString
		}
		guard let host = url.host, !host.isEmpty else {
			return nil
		}
		return urlString
	}
}
