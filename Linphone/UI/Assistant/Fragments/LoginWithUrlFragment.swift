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

import SwiftUI

// AccelerateNetworks: enter a remote provisioning URL by hand instead of scanning it as a QR code
struct LoginWithUrlFragment: View {
	
	@ObservedObject private var coreContext = CoreContext.shared
	
	@StateObject private var loginWithUrlViewModel = LoginWithUrlViewModel()
	@StateObject private var keyboard = KeyboardResponder()
	
	@Environment(\.dismiss) var dismiss
	
	@FocusState var isUrlFocused: Bool
	
	var body: some View {
		ZStack {
			GeometryReader { geometry in
				ScrollView(.vertical) {
					VStack {
						ZStack {
							HStack {
								Image("caret-left")
									.renderingMode(.template)
									.resizable()
									.foregroundStyle(Color.grayMain2c500)
									.frame(width: 25, height: 25)
									.padding(.all, 10)
									.onTapGesture {
										dismiss()
									}
								
								Spacer()
							}
							
							Text("assistant_login_with_url")
								.default_text_style_800(styleSize: 20)
						}
						.frame(width: geometry.size.width)
						.padding(.top, 10)
						.padding(.bottom, 20)
						
						VStack(alignment: .leading) {
							Text("assistant_login_with_url_label")
								.default_text_style_700(styleSize: 15)
								.padding(.bottom, -5)
							
							TextField("assistant_login_with_url_placeholder", text: $loginWithUrlViewModel.url)
								.default_text_style(styleSize: 15)
								.keyboardType(.URL)
								.textContentType(.URL)
								.disableAutocorrection(true)
								.autocapitalization(.none)
								.submitLabel(.go)
								.onSubmit {
									login()
								}
								.frame(height: 25)
								.padding(.horizontal, 20)
								.padding(.vertical, 15)
								.cornerRadius(60)
								.overlay(
									RoundedRectangle(cornerRadius: 60)
										.inset(by: 0.5)
										.stroke(isUrlFocused ? Color.orangeMain500 : Color.gray200, lineWidth: 1)
								)
								.padding(.bottom)
								.focused($isUrlFocused)
							
							Button(action: {
								login()
							}, label: {
								Text("assistant_account_login")
									.default_text_style_white_600(styleSize: 20)
									.frame(height: 35)
									.frame(maxWidth: .infinity)
							})
							.padding(.horizontal, 20)
							.padding(.vertical, 10)
							.background(isLoginDisabled ? Color.orangeMain100 : Color.orangeMain500)
							.cornerRadius(60)
							.disabled(isLoginDisabled)
							.padding(.bottom)
						}
						.frame(maxWidth: SharedMainViewModel.shared.maxWidth)
						.padding(.horizontal, 20)
						
						Spacer()
						
						Image("mountain2")
							.resizable()
							.scaledToFill()
							.frame(width: geometry.size.width, height: 60)
							.clipped()
					}
					.frame(minHeight: geometry.size.height)
					.padding(.bottom, keyboard.currentHeight)
				}
			}
			
			if loginWithUrlViewModel.isProvisioning {
				PopupLoadingView()
					.background(.black.opacity(0.65))
			}
		}
		.navigationTitle("")
		.navigationBarHidden(true)
		.edgesIgnoringSafeArea(.bottom)
		.edgesIgnoringSafeArea(.horizontal)
		.onAppear {
			// Keeps the assistant on screen while the core restarts to apply the
			// provisioning, same as when the QR code scanner is open
			coreContext.codeScannerIsOpen = true
		}
		.onDisappear {
			coreContext.codeScannerIsOpen = false
		}
	}
	
	private var isLoginDisabled: Bool {
		loginWithUrlViewModel.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		|| loginWithUrlViewModel.isProvisioning
	}
	
	private func login() {
		guard !isLoginDisabled else { return }
		isUrlFocused = false
		loginWithUrlViewModel.login()
	}
}

#Preview {
	LoginWithUrlFragment()
}
