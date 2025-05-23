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

import UserNotifications
import linphonesw
#if USE_CRASHLYTICS
import Firebase
#endif

var APP_GROUP_ID = "group.com.acceleratenetworks.mobile"
var LINPHONE_DUMMY_SUBJECT = "dummy subject"

struct MsgData: Codable {
    var from: String?
    var body: String?
    var subtitle: String?
    var callId: String?
    var localAddr: String?
    var peerAddr: String?
}

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    var lc: Core?
    static var logDelegate: LinphoneLoggingServiceManager!
	static var log: LoggingService!
	
	override init() {
		super.init()
#if USE_CRASHLYTICS
		FirebaseApp.configure()
#endif
	}

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
			self.contentHandler = contentHandler
			bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
			NSLog("[msgNotificationService] start msgNotificationService extension")

			if (VFSUtil.vfsEnabled(groupName: APP_GROUP_ID) && !VFSUtil.activateVFS()) {
				VFSUtil.log("[VFS] Error unable to activate.", .error)
			}
			
			if let bestAttemptContent = bestAttemptContent {
				createCore()
				
				if (!(lc!.config?.getBool(section: "app", key: "disable_chat_feature", defaultValue: true))!){
					NotificationService.log.message(message: "received push payload : \(bestAttemptContent.userInfo.debugDescription)")

					
					let defaults = UserDefaults.init(suiteName: APP_GROUP_ID)
					if let chatroomsPushStatus = defaults?.dictionary(forKey: "chatroomsPushStatus") {
						let aps = bestAttemptContent.userInfo["aps"] as? NSDictionary
						let alert = aps?["alert"] as? NSDictionary
						let fromAddresses = alert?["loc-args"] as? [String]
						
//						if let from = fromAddresses?.first {
//							if ((chatroomsPushStatus[from] as? String) == "disabled") {
//								NotificationService.log.message(message: "message comes from a muted chatroom, ignore it")
//								contentHandler(UNNotificationContent())
//							}
//						}
					}
					
					if let chatRoomInviteAddr = bestAttemptContent.userInfo["chat-room-addr"] as? String, !chatRoomInviteAddr.isEmpty {
						NotificationService.log.message(message: "fetch chat room for invite, addr: \(chatRoomInviteAddr)")
						let chatRoom = lc!.getNewChatRoomFromConfAddr(chatRoomAddr: chatRoomInviteAddr)

						if let chatRoom = chatRoom {
							stopCore()
							NotificationService.log.message(message: "chat room invite received")
							bestAttemptContent.title = NSLocalizedString("GC_MSG", comment: "")
							if (chatRoom.hasCapability(mask:ChatRoom.Capabilities.OneToOne.rawValue)) {
								if (chatRoom.peerAddress?.displayName?.isEmpty != true) {
									bestAttemptContent.body = chatRoom.peerAddress!.displayName!
								} else {
									bestAttemptContent.body = chatRoom.peerAddress!.username!
								}
							} else {
								bestAttemptContent.body = chatRoom.subject!
							}

							bestAttemptContent.sound = UNNotificationSound(named: UNNotificationSoundName("msg.caf")) // TODO : temporary fix, to be removed after flexisip release
							contentHandler(bestAttemptContent)
							return
						}
					} else if let callId = bestAttemptContent.userInfo["call-id"] as? String {
						NotificationService.log.message(message: "fetch msg for callid ["+callId+"]")
						let message = lc!.getNewMessageFromCallid(callId: callId)

						if let message = message {
							let msgData = parseMessage(message: message)

							// Extension only upates app's badge when main shared core is Off = extension's core is On.
							// Otherwise, the app will update the badge.
							if lc?.globalState == GlobalState.On, let badge = updateBadge() as NSNumber? {
								bestAttemptContent.badge = badge
							}

							stopCore()

							bestAttemptContent.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "msg.caf"))
							bestAttemptContent.title = NSLocalizedString("Message received", comment: "")
							if let subtitle = msgData?.subtitle {
								bestAttemptContent.subtitle = subtitle
							}
							if let body = msgData?.body {
								bestAttemptContent.body = body
							}

							bestAttemptContent.categoryIdentifier = "msg_cat"

							bestAttemptContent.userInfo.updateValue(msgData?.callId as Any, forKey: "CallId")
							bestAttemptContent.userInfo.updateValue(msgData?.from as Any, forKey: "from")
							bestAttemptContent.userInfo.updateValue(msgData?.peerAddr as Any, forKey: "peer_addr")
							bestAttemptContent.userInfo.updateValue(msgData?.localAddr as Any, forKey: "local_addr")
							
							if message.reactionContent != " " {
								contentHandler(bestAttemptContent)
							}else {
								contentHandler(UNNotificationContent())
							}
							
							return
						} else {
							NotificationService.log.message(message: "Message not found for callid ["+callId+"]")
						}
					}
				}
				serviceExtensionTimeWillExpire()
			}
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
		NotificationService.log.warning(message: "serviceExtensionTimeWillExpire")
		stopCore()
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            NSLog("[msgNotificationService] serviceExtensionTimeWillExpire")
            bestAttemptContent.categoryIdentifier = "app_active"

			if let chatRoomInviteAddr = bestAttemptContent.userInfo["chat-room-addr"] as? String, !chatRoomInviteAddr.isEmpty {
				bestAttemptContent.title = NSLocalizedString("GC_MSG", comment: "")
				bestAttemptContent.body = ""
				bestAttemptContent.sound = UNNotificationSound(named: UNNotificationSoundName("msg.caf")) // TODO : temporary fix, to be removed after flexisip release
			} else {
				bestAttemptContent.title = NSLocalizedString("Message received", comment: "")
				bestAttemptContent.body = NSLocalizedString("IM_MSG", comment: "")
			}
            contentHandler(bestAttemptContent)
        }
    }

	func parseMessage(message: PushNotificationMessage) -> MsgData? {
		
		var content = ""
		if (message.isConferenceInvitationNew) {
			content = NSLocalizedString("📅 You are invited to a meeting", comment: "")
		} else if (message.isConferenceInvitationUpdate) {
			content =  NSLocalizedString("📅 Meeting has been modified", comment: "")
		} else if (message.isConferenceInvitationCancellation) {
			content =  NSLocalizedString("📅 Meeting has been cancelled", comment: "")
		} else {
			content = message.isText ? message.textContent! : "🗻"
		}
		
		let fromAddr = message.fromAddr?.username
		let callId = message.callId
		let localUri = message.localAddr?.asStringUriOnly()
		let peerUri = message.peerAddr?.asStringUriOnly()
		let reactionContent = message.reactionContent
		let from: String
		if let fromDisplayName = message.fromAddr?.asStringUriOnly().getDisplayNameFromSipAddress(lc: lc!, logger: NotificationService.log, groupId: APP_GROUP_ID) {
			from = fromDisplayName
		} else {
			from = fromAddr!
		}


		var msgData = MsgData(from: fromAddr, body: "", subtitle: "", callId:callId, localAddr: localUri, peerAddr:peerUri)

		if let showMsg = lc!.config?.getBool(section: "app", key: "show_msg_in_notif", defaultValue: true), showMsg == true {
			if let subject = message.subject as String?, subject != "" {
				msgData.subtitle = subject
				if reactionContent == nil {
					msgData.body = from + " : " + content
				} else {
					msgData.body = from + NSLocalizedString(" has reacted by ", comment: "") + reactionContent! + NSLocalizedString(" to: ", comment: "") + content
				}
			} else {
				msgData.subtitle = from
				msgData.body = content
			}
		} else {
			if let subject = message.subject as String?, subject != "" {
				msgData.body = subject + " : " + from
			} else {
				msgData.body = from
			}
		}

		NotificationService.log.message(message: "received msg size : \(content.count) \n")
		return msgData;
	}

	func createCore() {
		NSLog("[msgNotificationService] create core")
		
		let config = Config.newForSharedCore(appGroupId: APP_GROUP_ID, configFilename: "linphonerc", factoryConfigFilename: "")

		if (NotificationService.log == nil) {
			NotificationService.log = LoggingService.Instance /*enable liblinphone logs.*/
			NotificationService.logDelegate = try! LinphoneLoggingServiceManager(config: config!, log: NotificationService.log, domain: "msgNotificationService")
		}
		lc = try! Factory.Instance.createSharedCoreWithConfig(config: config!, systemContext: nil, appGroupId: APP_GROUP_ID, mainCore: false)


		// Disable auto downloads in service extension
		
		// Save config values
		let configMaxSizeForAutoDownloadIncomingFiles = config?.getInt(section: "app", key: "auto_download_incoming_files_max_size", defaultValue: -1)
		let configAutoDownloadVoiceRecordingsEnabled = config?.getBool(section: "app", key: "auto_download_incoming_voice_recordings", defaultValue: true)

		// Disable downloads in service extension (API calls below will set the core attributes value + config)
		lc?.maxSizeForAutoDownloadIncomingFiles = -1
		lc?.autoDownloadVoiceRecordingsEnabled = false
		
		// restore the config values for the app
		config?.setInt(section: "app", key: "auto_download_incoming_files_max_size", value: configMaxSizeForAutoDownloadIncomingFiles!)
		config?.setBool(section: "app", key: "auto_download_incoming_voice_recordings", value: configAutoDownloadVoiceRecordingsEnabled!)
	}

	func stopCore() {
		NotificationService.log.message(message: "stop core")
		if let lc = lc {
			lc.stop()
		}
	}

    func updateBadge() -> Int {
        var count = 0
        count += lc!.unreadChatMessageCount
        count += lc!.missedCallsCount
        count += lc!.callsNb
		NotificationService.log.message(message: "badge: \(count)\n")

        return count
    }

}
