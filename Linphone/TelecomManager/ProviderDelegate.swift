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
// swiftlint:disable line_length

import Foundation
import CallKit
import UIKit
import linphonesw
import AVFoundation
import os
import SwiftUI

class CallInfo {
	var callId: String = ""
	var toAddr: Address?
	var isOutgoing = false
	var sasEnabled = false
	var connected = false
	var reason: Reason = Reason.None
	var displayName: String?
	var videoEnabled = false
	var isConference = false
	
	static func newIncomingCallInfo(callId: String) -> CallInfo {
		let callInfo = CallInfo()
		callInfo.callId = callId
		return callInfo
	}
	
	static func newOutgoingCallInfo(addr: Address, isSas: Bool, displayName: String, isVideo: Bool, isConference: Bool) -> CallInfo {
		let callInfo = CallInfo()
		callInfo.isOutgoing = true
		callInfo.sasEnabled = isSas
		callInfo.toAddr = addr
		callInfo.displayName = displayName
		callInfo.videoEnabled = isVideo
		callInfo.isConference = isConference
		return callInfo
	}
}

/*
 * A delegate to support callkit.
 */
class ProviderDelegate: NSObject {
	let provider: CXProvider

	// `uuids`/`callInfos` mirror CallKit's own call bookkeeping. Every CXProviderDelegate callback
	// runs on the main queue (provider.setDelegate(self, queue: nil)), but onCallStateChanged /
	// doOnCoreQueue mutate the same mirror from the core queue. `mirrorLock` serializes every
	// membership change and read below so the two queues cannot race (an-mobile-ios#44).
	// `actionToFulFill` has the same two-queue exposure (CXSetHeldCallAction on the core queue,
	// providerDidReset on the main queue) and is folded into the same lock.
	private var uuids: [String: UUID] = [:]
	private var callInfos: [UUID: CallInfo] = [:]
	private var actionToFulFill: CXCallAction?
	private let mirrorLock = NSLock()

	override init() {
		provider = CXProvider(configuration: ProviderDelegate.providerConfiguration)
		super.init()
		provider.setDelegate(self, queue: nil)
	}

	// MARK: - Owned, serialized mirror surface (an-mobile-ios#44)

	/// Insert a call, keyed by both its CallKit UUID and its (possibly sentinel `""`) call-id.
	///
	/// If `callId` is already claimed by a *different* UUID, that UUID is displaced: forgotten from
	/// the mirror and told to end via CallKit. Without this, CallKit is left believing the displaced
	/// UUID is still a live call forever - observed 2026-09-24 when a call got started twice in quick
	/// succession (state transitions for one real call raced two `track`/`rekey` calls): the first
	/// UUID was silently evicted from `uuids` and never ended, leaving CallKit's own call screen
	/// stuck on it (an-mobile-ios#44's class of bug, a second instance).
	func track(_ info: CallInfo, uuid: UUID, callId: String) {
		mirrorLock.lock()
		let displaced = displaceLocked(callId: callId, for: uuid)
		info.callId = callId
		callInfos[uuid] = info
		uuids[callId] = uuid
		mirrorLock.unlock()
		if let displaced = displaced {
			endCall(uuid: displaced)
		}
	}

	/// Remove a call's mirror entries. Idempotent: safe to call on an already-forgotten UUID.
	func forget(uuid: UUID) {
		mirrorLock.lock()
		if let callId = callInfos[uuid]?.callId {
			uuids.removeValue(forKey: callId)
		}
		callInfos.removeValue(forKey: uuid)
		mirrorLock.unlock()
	}

	/// CallKit has dropped every call it held (providerDidReset); nothing left in the mirror is
	/// reachable.
	func forgetAll() {
		mirrorLock.lock()
		uuids.removeAll()
		callInfos.removeAll()
		mirrorLock.unlock()
	}

	/// Move a tracked call's key from its current call-id to `callId` (which may itself be the `""`
	/// sentinel), keeping `CallInfo.callId` in sync. No-op if `uuid` isn't tracked. Displaces (and
	/// ends) any other UUID already occupying the destination key - see `track(_:uuid:callId:)`.
	func rekey(uuid: UUID, to callId: String) {
		mirrorLock.lock()
		guard let info = callInfos[uuid] else {
			mirrorLock.unlock()
			return
		}
		let displaced = displaceLocked(callId: callId, for: uuid)
		uuids.removeValue(forKey: info.callId)
		info.callId = callId
		uuids[callId] = uuid
		mirrorLock.unlock()
		if let displaced = displaced {
			endCall(uuid: displaced)
		}
	}

	/// Must be called with `mirrorLock` held. If `callId` is currently mapped to a UUID other than
	/// `uuid`, removes that UUID's mirror entries and returns it so the caller can end its CallKit
	/// call once the lock is released (CXProvider calls must not be made while holding the lock).
	private func displaceLocked(callId: String, for uuid: UUID) -> UUID? {
		guard let existing = uuids[callId], existing != uuid else { return nil }
		callInfos.removeValue(forKey: existing)
		return existing
	}

	/// The shared `CallInfo` instance for `uuid`. The lock covers membership only: do not read
	/// `.callId` off the returned instance, since `track`/`rekey` rewrite it under `mirrorLock` from
	/// the core queue. Use `callId(for:)` instead.
	func info(for uuid: UUID) -> CallInfo? {
		mirrorLock.lock()
		defer { mirrorLock.unlock() }
		return callInfos[uuid]
	}

	/// The call-id currently bound to `uuid`, read under `mirrorLock`. `nil` if `uuid` isn't tracked;
	/// `""` if it is a pending outgoing call whose call-id hasn't bound yet.
	func callId(for uuid: UUID) -> String? {
		mirrorLock.lock()
		defer { mirrorLock.unlock() }
		return callInfos[uuid]?.callId
	}

	func uuid(forCallId callId: String) -> UUID? {
		mirrorLock.lock()
		defer { mirrorLock.unlock() }
		return uuids[callId]
	}

	/// A point-in-time (call-id, uuid) snapshot of every tracked entry, for callers that must walk
	/// the whole mirror (registration-state teardown). Membership changes made after the snapshot is
	/// taken are not reflected in it.
	func snapshotEntries() -> [(callId: String, uuid: UUID)] {
		mirrorLock.lock()
		defer { mirrorLock.unlock() }
		return uuids.map { (callId: $0.key, uuid: $0.value) }
	}

	func setActionToFulFill(_ action: CXCallAction?) {
		mirrorLock.lock()
		actionToFulFill = action
		mirrorLock.unlock()
	}

	/// Fulfil and clear the pending action in one step, so nothing else can observe it between the
	/// two. No-op if nothing is pending.
	func fulfillAndClearActionToFulFill() {
		mirrorLock.lock()
		let action = actionToFulFill
		actionToFulFill = nil
		mirrorLock.unlock()
		action?.fulfill()
	}
	
	static var providerConfiguration: CXProviderConfiguration {
		let providerConfiguration = CXProviderConfiguration()
		// providerConfiguration.ringtoneSound = ConfigManager.instance().lpConfigBoolForKey(key: "use_device_ringtone") ? nil : "notes_of_the_optimistic.caf"
		providerConfiguration.supportsVideo = true
		providerConfiguration.iconTemplateImageData = UIImage(named: "linphone")?.pngData()
		providerConfiguration.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]
		
		providerConfiguration.maximumCallsPerCallGroup = 10
		providerConfiguration.maximumCallGroups = 10
		
		// not show app's calls in tel's history
		// providerConfiguration.includesCallsInRecents = YES;
		
		return providerConfiguration
	}
	
	func reportIncomingCall(call: Call?, uuid: UUID, handle: String, hasVideo: Bool, displayName: String) {
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type: .generic, value: handle)
		update.hasVideo = hasVideo
		update.localizedCallerName = displayName
		
		let callInfo = info(for: uuid)
		let callId = self.callId(for: uuid) ?? ""

		/*
		 if (ConfigManager.instance().config?.hasEntry(section: "app", key: "max_calls") == 1)  { // moved from misc to app section intentionally upon app start or remote configuration
		 if let maxCalls = ConfigManager.instance().config?.getInt(section: "app",key: "max_calls",defaultValue: 10), Core.get().callsNb > maxCalls {
		 Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: declining call, as max calls (\(maxCalls)) reached  call-id: [\(String(describing: callId))] and UUID: [\(uuid.description)]")
		 decline(uuid: uuid)
		 
		 CoreContext.shared.doOnCoreQueue(synchronous: true) { core in
		 try? call?.decline(reason: .Busy)
		 }
		 return
		 }
		 }
		 */
		
		Log.info("CallKit: report new incoming call with call-id: [\(callId)] and UUID: [\(uuid.description)]")
		// TelecomManager.instance().setHeldOtherCalls(exceptCallid: callId ?? "") // ALREADY COMMENTED ON LINPHONE-IPHONE 5.2
		provider.reportNewIncomingCall(with: uuid, update: update) { error in
			if error == nil {
				if TelecomManager.shared.endCallkit {
					CoreContext.shared.doOnCoreQueue(synchronous: true) { core in
						let call = core.getCallByCallid(callId: callId)
						if call?.state == .PushIncomingReceived {
							try? call?.terminate()
						}
					}
				}
			} else {
				Log.error("CallKit: cannot complete incoming call with call-id: [\(callId)] and UUID: [\(uuid.description)] from [\(handle)] caused by [\(error!.localizedDescription)]")
				let code = (error as NSError?)?.code
				switch code {
				case CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue:
					callInfo?.reason = Reason.Busy	// This answer is only for this device. Using Reason.DoNotDisturb will make all other end point stop ringing.
				case CXErrorCodeIncomingCallError.filteredByBlockList.rawValue:
					callInfo?.reason = Reason.DoNotDisturb
				default:
					callInfo?.reason = Reason.Unknown
				}
				// CallInfo is a class - callInfo is the same instance already stored in the mirror,
				// so mutating .reason above already updated it; no write-back needed.
				CoreContext.shared.doOnCoreQueue(synchronous: true) { _ in
					try? call?.decline(reason: callInfo!.reason)
				}
			}
		}
	}
	
	func updateCall(uuid: UUID, handle: String, hasVideo: Bool = false, displayName: String) {
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type: .generic, value: handle)
		update.localizedCallerName = displayName
		update.hasVideo = hasVideo
		provider.reportCall(with: uuid, updated: update)
	}
	
	func reportOutgoingCallStartedConnecting(uuid: UUID) {
		provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
	}
	
	func reportOutgoingCallConnected(uuid: UUID) {
		provider.reportOutgoingCall(with: uuid, connectedAt: nil)
	}
	
	func endCall(uuid: UUID) {
		provider.reportCall(with: uuid, endedAt: .init(), reason: .failed)
	}
	
	func decline(uuid: UUID) {
		provider.reportCall(with: uuid, endedAt: .init(), reason: .unanswered)
	}
	
	func endCallNotExist(uuid: UUID, timeout: DispatchTime) {
		DispatchQueue.main.asyncAfter(deadline: timeout) {
			CoreContext.shared.doOnCoreQueue(synchronous: true) { core in
				let callId = self.callId(for: uuid)
				if callId == nil {
					// callkit already ended
					return
				}
				if core.getCallByCallid(callId: callId ?? "") == nil {
					Log.info("CallKit: terminate call with call-id: \(String(describing: callId)) and UUID: \(uuid) which does not exist.")
					self.endCall(uuid: uuid)
				}
			}
		}
	}
}

// MARK: - CXProviderDelegate
extension ProviderDelegate: CXProviderDelegate {
	func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		
		let uuid = action.callUUID

		CoreContext.shared.doOnCoreQueue { core in
			// Resolve the call-id on the core queue, not here: an outgoing call's call-id is bound by
			// `rekey` during `.OutgoingInit`, which runs on the core queue inside the CXStartCallAction
			// block. Reading it on the main queue can observe the `""` sentinel from before that bind,
			// miss the core call, and then forget the only handle to it. Queued behind the start
			// block, this read always sees the bound call-id.
			let callId = self.callId(for: uuid)

			// remove call infos before terminating, otherwise CXEndCallAction will be called more than
			// once (the resulting `.End` state change would find the uuid still tracked)
			self.forget(uuid: uuid)

			if let call = core.getCallByCallid(callId: callId ?? "") {
				TelecomManager.shared.terminateCall(call: call)
				Log.info("CallKit: Call ended with call-id: \(String(describing: callId)) an UUID: \(uuid.description).")
			}
			action.fulfill()
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		let uuid = action.callUUID
		let callInfo = info(for: uuid)

		// An answer can arrive after the call has already ended, in which case its CallInfo is gone.
		// Setting callInProgress on that path latches it: nothing clears it without a further call
		// state change, and none is coming for a call that no longer exists.
		if callInfo == nil {
			Log.error("CallKit: answer for UUID [\(uuid.description)] has no live call, failing the action.")
			action.fail()
			endCall(uuid: uuid)
			return
		}
		
		if TelecomManager.shared.callInProgress == false {
			DispatchQueue.main.async {
				withAnimation {
					TelecomManager.shared.callInProgress = true
					TelecomManager.shared.callDisplayed = true
				}
			}
		}
		CoreContext.shared.doOnCoreQueue { core in
			let callId = self.callId(for: uuid) ?? ""
			Log.info("CallKit: answer call with call-id: \(String(describing: callId)) and UUID: \(uuid.description).")
			
			let call = core.getCallByCallid(callId: callId)
			
			let callLogIsNil = call?.callLog != nil
			
			let videoEnabledTmp = call?.params?.videoEnabled
			let wasConferenceTmp = call?.callLog?.wasConference()
			
			DispatchQueue.main.async {
				if UIApplication.shared.applicationState != .active {
					TelecomManager.shared.backgroundContextCall = call
					if callLogIsNil {
						TelecomManager.shared.backgroundContextCameraIsEnabled = videoEnabledTmp == true || wasConferenceTmp == true
					} else {
						TelecomManager.shared.backgroundContextCameraIsEnabled = videoEnabledTmp == true
					}
					
					if #available(iOS 16.0, *) {
						if call?.cameraEnabled == true {
							call?.cameraEnabled = AVCaptureSession().isMultitaskingCameraAccessSupported
						}
					} else {
						call?.cameraEnabled = false // Disable camera while app is not on foreground
					}
				}
			}
			TelecomManager.shared.callkitAudioSessionActivated = false
			core.configureAudioSession()
			
			if call != nil {
				TelecomManager.shared.acceptCall(core: core, call: call!, hasVideo: call!.params?.videoEnabled ?? false)
			}
			
			action.fulfill()
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
		let uuid = action.callUUID

		CoreContext.shared.doOnCoreQueue { core in
			let callId = self.callId(for: uuid) ?? ""
			let call = core.getCallByCallid(callId: callId)
			
			if call == nil {
				Log.error("CXSetHeldCallAction: no call !")
				action.fail()
				return
			}
			
			do {
				if call?.conference != nil && action.isOnHold {
					_ = call?.conference?.leave()
					Log.info("CallKit: call-id: [\(callId)] leaving conference")
					NotificationCenter.default.post(name: Notification.Name("LinphoneCallUpdate"), object: self)
					action.fulfill()
				} else {
					let state = action.isOnHold ? "Paused" : "Resumed"
					Log.info("CallKit: Call  with call-id: [\(callId)] and UUID: [\(uuid)] paused status changed to: [\(state)]")
					if action.isOnHold {
						TelecomManager.shared.speakerBeforePause = AudioRouteUtils.isSpeakerAudioRouteCurrentlyUsed(core: core, call: call)
						try call!.pause()
						// fullfill() the action now to indicate to Callkit that this call is no longer active, even if the
						// SIP transaction is not completed yet. At this stage, the media streams are off.
						// If callkit is not aware that the pause action is completed, it will terminate this call if we
						// attempt to resume another one.
						action.fulfill()
					} else {
						if call != nil && call?.conference != nil && core.callsNb > 1 {
							_ = call!.conference!.enter()
							self.setActionToFulFill(action)
						} else {
							try call!.resume()
							// We'll notify callkit that the action is fulfilled when receiving the 200Ok, which is the point
							// where we actually start the media streams.
							self.setActionToFulFill(action)
							// HORRIBLE HACK HERE - PLEASE APPLE FIX THIS !!
							// When resuming a SIP call after a native call has ended remotely, didActivate: audioSession
							// is never called.
							// It looks like in this case, it is implicit.
							// As a result we have to notify the Core that the AudioSession is active.
							// The SpeakerBox demo application written by Apple exhibits this behavior.
							// https://developer.apple.com/documentation/callkit/making_and_receiving_voip_calls_with_callkit
							// We can clearly see there that startAudio() is called immediately in the CXSetHeldCallAction
							// handler, while it is called from didActivate: audioSession otherwise.
							// Callkit's design is not consistent, or its documentation imcomplete, wich is somewhat disapointing.
							//
							
							Log.info("Assuming AudioSession is active when executing a CXSetHeldCallAction with isOnHold=false.")
							core.activateAudioSession(activated: true)
							TelecomManager.shared.callkitAudioSessionActivated = true
						}
					}
				}
			} catch {
				Log.error("CallKit: Call set held (paused or resumed) \(uuid) failed because \(error)")
				action.fail()
			}
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		let uuid = action.callUUID
		let callInfo = info(for: uuid)
		let update = CXCallUpdate()
		update.remoteHandle = action.handle
		update.localizedCallerName = callInfo?.displayName
		self.provider.reportCall(with: action.callUUID, updated: update)
		
		let addr = callInfo?.toAddr
		if addr == nil {
			Log.info("CallKit: can not call a null address!")
			action.fail()
		} else {
			CoreContext.shared.doOnCoreQueue { core in
				do {
					core.configureAudioSession()
					try TelecomManager.shared.doCall(core: core, addr: addr!, isSas: callInfo?.sasEnabled ?? false, isVideo: callInfo?.videoEnabled ?? false, isConference: callInfo?.isConference ?? false)
					action.fulfill()
				} catch {
					Log.info("CallKit: Call started failed because \(error)")
					// CallKit drops the call on fail(), so the mirrors must drop it too. uuids[""]
					// is the single slot outgoing calls occupy until their call-id binds; leaving a
					// dead uuid there makes the next lookup for "" resolve to a call that never existed.
					// `forget` clears that slot, since a refused call's callId is still "".
					self.forget(uuid: uuid)
					action.fail()
				}
			}
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
		CoreContext.shared.doOnCoreQueue { core in
			Log.info("CallKit: Call grouped callUUid : \(action.callUUID) with callUUID: \(String(describing: action.callUUIDToGroupWith)).")
			TelecomManager.shared.addAllToLocalConference(core: core)
			action.fulfill()
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		let uuid = action.callUUID
		CoreContext.shared.doOnCoreQueue { core in
			let callId = self.callId(for: uuid)
			Log.info( "CallKit: Call muted with call-id: \(String(describing: callId)) an UUID: \(uuid.description).")
			core.micEnabled = !core.micEnabled
			action.fulfill()
		}
	}
	
	func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
		let uuid = action.callUUID

		CoreContext.shared.doOnCoreQueue { core in
			let callId = self.callId(for: uuid) ?? ""
			Log.info("CallKit: Call send dtmf with call-id: \(callId) an UUID: \(uuid.description).")
			if let call = core.getCallByCallid(callId: callId) {
				let digit = (action.digits.cString(using: String.Encoding.utf8)?[0])!
				do {
					try call.sendDtmf(dtmf: digit)
				} catch {
					Log.error("CallKit: Call send dtmf \(uuid) failed because \(error)")
				}
			}
			action.fulfill()
		}
	}
	
	func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
		let uuid = action.uuid
		let callId = self.callId(for: uuid)
		Log.error("CallKit: Call time out with call-id: \(String(describing: callId)) an UUID: \(uuid.description).")
		action.fulfill()
	}
	
	func providerDidReset(_ provider: CXProvider) {
		Log.info("CallKit: did reset.")
		// CallKit has dropped every call it held, so anything left in these maps is unreachable.
		forgetAll()
		// actionToFulFill holds a CXCallAction from a transaction CallKit has just discarded.
		setActionToFulFill(nil)
		// CallKit's contract is that the app ends its calls on reset. Without this a core call keeps
		// running with audio, unreachable from CallKit and no longer holding callInProgress, so the
		// next backgrounding can stop the core under it.
		CoreContext.shared.doOnCoreQueue { core in
			do {
				try core.terminateAllCalls()
			} catch {
				Log.error("CallKit: terminateAllCalls after provider reset failed because \(error)")
			}
		}
		TelecomManager.shared.resetCallState()
	}
	
	func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
		CoreContext.shared.doOnCoreQueue { core in
			Log.info("CallKit: audio session activated.")
			core.activateAudioSession(activated: true)
			TelecomManager.shared.callkitAudioSessionActivated = true
		}
	}
	
	func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
		CoreContext.shared.doOnCoreQueue { core in
			Log.info("CallKit: audio session deactivated.")
			core.activateAudioSession(activated: false)
			TelecomManager.shared.callkitAudioSessionActivated = nil
		}
	}
}
// swiftlint:enable line_length
