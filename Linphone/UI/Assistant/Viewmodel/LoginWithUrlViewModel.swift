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
	
	private var mCoreDelegate: CoreDelegate?
	
	init() {
		mCoreDelegate = CoreDelegateStub(
			onConfiguringStatus: { (_: Core, status: ConfiguringState, message: String) in
				Log.info("\(LoginWithUrlViewModel.TAG) New configuration state is \(status) = \(message)")
				self.handleConfigurationChanged(status: status)
			}
		)
		
		if let delegate = mCoreDelegate {
			coreContext.doOnCoreQueue { core in
				core.addDelegate(delegate: delegate)
			}
		}
	}
	
	deinit {
		if let delegate = mCoreDelegate {
			coreContext.doOnCoreQueue { core in
				core.removeDelegate(delegate: delegate)
			}
		}
	}
	
	@MainActor
	func login() {
		guard let provisioningUrl = LinphoneUtils.getRemoteProvisioningUrl(from: url) else {
			ToastViewModel.shared.show("Invalide URI")
			return
		}

		Log.info("\(LoginWithUrlViewModel.TAG) Setting remote provisioning URI and restarting the Core")
		isProvisioning = true

		coreContext.doOnCoreQueue { core in
			do {
				try core.setProvisioninguri(newValue: provisioningUrl)
			} catch {
				Log.error("\(LoginWithUrlViewModel.TAG) Unable to set provisioning URI \(provisioningUrl): \(error)")
				DispatchQueue.main.async {
					self.isProvisioning = false
					ToastViewModel.shared.show("Invalide URI")
				}
				return
			}
			core.stop()
			try? core.start()
		}
	}
	
	private func handleConfigurationChanged(status: ConfiguringState) {
		switch status {
		case .Successful:
			// No toast here: the only success toast says "QR code validated", and the
			// assistant closes on its own once the provisioned account shows up.
			DispatchQueue.main.async {
				self.isProvisioning = false
			}
		case .Failed:
			DispatchQueue.main.async {
				self.isProvisioning = false
				ToastViewModel.shared.show("Invalide URI")
			}
		default:
			break
		}
	}
}
