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

import linphonesw
import Foundation

// AccelerateNetworks: remote provisioning from a typed-in URL, the manual counterpart of the QR scanner
class LoginWithUrlViewModel: ObservableObject {
	
	static let TAG = "[LoginWithUrlViewModel]"
	
	private var coreContext = CoreContext.shared
	
	@Published var url: String = ""
	@Published var isProvisioning: Bool = false
	
	@MainActor
	func login() {
		let trimmedUrl = LoginWithUrlViewModel.provisioningUrl(from: url.trimmingCharacters(in: .whitespacesAndNewlines))
		
		guard let parsedUrl = URL(string: trimmedUrl),
			  let scheme = parsedUrl.scheme?.lowercased(),
			  scheme == "http" || scheme == "https",
			  parsedUrl.host != nil else {
			ToastViewModel.shared.show("Invalide URI")
			return
		}
		
		Log.info("\(LoginWithUrlViewModel.TAG) Setting remote provisioning URI and restarting the Core")
		isProvisioning = true
		
		coreContext.doOnCoreQueue { [weak self] core in
			let accountIdentitiesBefore = ProvisioningObserver.accountIdentities(core: core)
			do {
				try core.setProvisioninguri(newValue: trimmedUrl)
			} catch {
				Log.error("\(LoginWithUrlViewModel.TAG) Unable to set provisioning URI \(trimmedUrl): \(error)")
				DispatchQueue.main.async {
					self?.isProvisioning = false
					ToastViewModel.shared.show("Invalide URI")
				}
				return
			}
			ProvisioningObserver.observe(core: core, accountIdentitiesBefore: accountIdentitiesBefore) {
				self?.isProvisioning = false
			}
			core.stop()
			try? core.start()
		}
	}
	
	/// Turns a `linphone-config://host/path` link into `https://host/path`, the same way
	/// URIHandler does when the app is opened with one. Other input is returned unchanged.
	static func provisioningUrl(from input: String) -> String {
		let configScheme = "linphone-config:"
		guard input.lowercased().hasPrefix(configScheme) else {
			return input
		}
		
		var urlString = String(input.dropFirst(configScheme.count))
		if urlString.hasPrefix("//") {
			urlString = String(urlString.dropFirst(2))
		}
		
		let lowercased = urlString.lowercased()
		if !lowercased.hasPrefix("https://") && !lowercased.hasPrefix("http://") {
			urlString = "https://" + urlString
		}
		return urlString
	}
}

/// Reports the outcome of one provisioning attempt, then removes itself from the core.
/// It is not owned by the screen: from "Add an account" the screen is dismissed as soon as the
/// core restarts, and the result still has to reach the user.
private final class ProvisioningObserver {
	
	// Keeps each observer alive until its attempt has an outcome. Only touched on the core queue.
	private static var pending: [ObjectIdentifier: ProvisioningObserver] = [:]
	
	private let accountIdentitiesBefore: Set<String>
	private let onFinished: () -> Void
	private var delegate: CoreDelegate?
	private var configurationSucceeded = false
	
	static func accountIdentities(core: Core) -> Set<String> {
		return Set(core.accountList.compactMap { $0.params?.identityAddress?.asStringUriOnly() })
	}
	
	/// Call on the core queue, before restarting the core. `onFinished` runs on the main queue.
	static func observe(core: Core, accountIdentitiesBefore: Set<String>, onFinished: @escaping () -> Void) {
		let observer = ProvisioningObserver(accountIdentitiesBefore: accountIdentitiesBefore, onFinished: onFinished)
		pending[ObjectIdentifier(observer)] = observer
		observer.start(core: core)
	}
	
	private init(accountIdentitiesBefore: Set<String>, onFinished: @escaping () -> Void) {
		self.accountIdentitiesBefore = accountIdentitiesBefore
		self.onFinished = onFinished
	}
	
	private func start(core: Core) {
		let delegate = CoreDelegateStub(
			onGlobalStateChanged: { [weak self] (core: Core, state: GlobalState, _: String) in
				if state == .On {
					self?.coreStarted(core: core)
				}
			},
			onConfiguringStatus: { [weak self] (core: Core, status: ConfiguringState, message: String) in
				Log.info("\(LoginWithUrlViewModel.TAG) New configuration state is \(status) = \(message)")
				self?.configuringStatusChanged(core: core, status: status)
			}
		)
		self.delegate = delegate
		core.addDelegate(delegate: delegate)
	}
	
	private func configuringStatusChanged(core: Core, status: ConfiguringState) {
		switch status {
		case .Successful:
			// Accounts from the provisioned config only exist once the core is On.
			configurationSucceeded = true
		case .Failed, .Skipped:
			finish(core: core, toast: "Invalide URI")
		default:
			break
		}
	}
	
	private func coreStarted(core: Core) {
		guard configurationSucceeded else { return }
		
		// No toast when an account was added: the assistant closes on its own once it shows up.
		if ProvisioningObserver.accountIdentities(core: core).subtracting(accountIdentitiesBefore).isEmpty {
			Log.warn("\(LoginWithUrlViewModel.TAG) Provisioning succeeded but did not add any account")
			finish(core: core, toast: "Failed_login_with_url_no_account")
		} else {
			finish(core: core, toast: nil)
		}
	}
	
	private func finish(core: Core, toast: String?) {
		if let delegate = delegate {
			core.removeDelegate(delegate: delegate)
		}
		delegate = nil
		ProvisioningObserver.pending[ObjectIdentifier(self)] = nil
		
		let onFinished = self.onFinished
		DispatchQueue.main.async {
			onFinished()
			if let toast = toast {
				ToastViewModel.shared.show(toast)
			}
		}
	}
}
