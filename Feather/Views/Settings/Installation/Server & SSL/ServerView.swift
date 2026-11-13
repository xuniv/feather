//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleJSON
import NimbleViews

// MARK: - Extension: Model
extension ServerView {
	struct ServerPackModel: Decodable {
		var cert: String
		var ca: String
		var key: String
		var info: ServerPackInfo
		
		private enum CodingKeys: String, CodingKey {
			case cert, ca, key1, key2, info
		}
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			cert = try container.decode(String.self, forKey: .cert)
			ca = try container.decode(String.self, forKey: .ca)
			let key1 = try container.decode(String.self, forKey: .key1)
			let key2 = try container.decode(String.self, forKey: .key2)
			key = key1 + key2
			info = try container.decode(ServerPackInfo.self, forKey: .info)
		}
		
		struct ServerPackInfo: Decodable {
			var issuer: Domains
			var domains: Domains
		}
		
		struct Domains: Decodable {
			var commonName: String
			
			private enum CodingKeys: String, CodingKey {
				case commonName = "commonName"
			}
		}
	}
}

// MARK: - View
struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	private let _serverMethods: [String] = [.localized("Local CA (Offline)"), .localized("Semi Local"), .localized("Public TLS")]
	@State private var _resetCA = false
	
	private let _dataService = NBFetchService()
	private let _serverPackUrl = "https://backloop.dev/pack.json"
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			}
			
			if _serverMethod == 0 {
				Section {
					Button(.localized("Set Up Local CA"), systemImage: "certificate") {
						do { try LocalTLSAuthority.shared.openSetup() } catch { showError(error) }
					}
					Button(.localized("Check Local CA Trust"), systemImage: "checkmark.shield") {
						do {
							try LocalTLSAuthority.shared.requireTrust()
							UIAlertController.showAlertWithOk(title: .localized("Local CA"), message: .localized("Local HTTPS is trusted."))
						} catch { showError(error) }
					}
					Button(.localized("Reset Local CA"), role: .destructive) { _resetCA = true }
				} footer: {
					Text(.localized("Set Up Local CA opens a profile in Safari. Install it in iOS Settings → General → VPN & Device Management, then enable full trust in General → About → Certificate Trust Settings. Keep Feather open during installation. The CA is unique to this app installation; its private key is discarded after issuing the localhost certificate."))
				}
			}
			if _serverMethod != 0 {
			Section {
				Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
					FR.downloadSSLCertificates(from: _serverPackUrl) { success in
						if success {
							DispatchQueue.main.async {
								UIAlertController.showAlertWithOk(
									title: .localized("SSL Certificates"),
									message: .localized("Certificates updated successfully.")
								)
							}
						} else {
							DispatchQueue.main.async {
								UIAlertController.showAlertWithOk(
									title: .localized("SSL Certificates"),
									message: .localized("Failed to download, check your internet connection and try again.")
								)
							}
						}
					}
				}
			}
			}
		}
		.confirmationDialog(.localized("Reset Local CA?"), isPresented: $_resetCA, titleVisibility: .visible) {
			Button(.localized("Reset and Set Up"), role: .destructive) {
				do { try LocalTLSAuthority.shared.reset(); try LocalTLSAuthority.shared.openSetup() } catch { showError(error) }
			}
		} message: {
			Text(.localized("Remove the old Feather CA profile in iOS Settings, then install and trust the replacement profile."))
		}
	}

	private func showError(_ error: Error) {
		UIAlertController.showAlertWithOk(title: .localized("Local CA"), message: error.localizedDescription)
	}
}
