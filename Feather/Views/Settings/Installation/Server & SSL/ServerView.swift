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
	@AppStorage("Feather.localInstallHost") private var _localHost = InstallationTransport.preferredLocalHost
	@AppStorage("Feather.hostedPlistServer") private var _hostedServer = InstallationTransport.defaultHostedServer
	private var method: InstallationServerMethod { InstallationServerMethod(rawValue: _serverMethod) ?? .localCA }
	@State private var _resetCA = false
	
	private let _serverPackUrl = "https://backloop.dev/pack.json"
	
	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(InstallationServerMethod.allCases, id: \.rawValue) { method in
						Text(.localized(method.title)).tag(method.rawValue)
					}
				}
				if method.usesHTTP {
					Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
				}
				if method.usesLocalCA {
					Picker(.localized("Local HTTPS Address"), selection: $_localHost) {
						ForEach(InstallationTransport.localHosts, id: \.self) { Text($0).tag($0) }
					}
				}
			}
			
			if method.usesLocalCA {
				Section {
					Button(.localized("Set Up Local CA"), systemImage: "certificate") {
						do { try LocalTLSAuthority.shared.openSetup() } catch { showError(error) }
					}
					Button(.localized("Check Local CA Trust"), systemImage: "checkmark.shield") {
						do {
							let host = try LocalTLSAuthority.shared.hostCandidates(preferred: _localHost)[0]
							try LocalTLSAuthority.shared.requireTrust(host: host)
							UIAlertController.showAlertWithOk(title: .localized("Local CA"), message: "Local HTTPS is trusted for \(host).")
						} catch { showError(error) }
					}
					Button(.localized("Reset Local CA"), role: .destructive) { _resetCA = true }
				} footer: {
					Text(.localized("Set Up Local CA opens a profile in Safari. Install it in iOS Settings → General → VPN & Device Management, then enable full trust in General → About → Certificate Trust Settings. Keep Feather open during installation. The CA is unique to this app installation; its private key is discarded after issuing the localhost certificate. Existing trusted certificates use localhost automatically. To add feather.localhost to an older certificate, explicitly reset the CA and trust the replacement profile."))
				}
			}
			if method.usesHostedManifest {
				Section {
					TextField("HTTPS Plist Server", text: $_hostedServer)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.URL)
					Button(.localized("Use Default Plist Server")) {
						_hostedServer = InstallationTransport.defaultHostedServer
					}
				} footer: {
					Text(.localized("The hosted server receives the app name, bundle ID, version and local download URL to create an HTTPS manifest. The IPA and certificates stay on this device. Hosted Plist (HTTP) does not require a Local CA."))
				}
			}
			if method == .publicTLS {
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
		UIAlertController.showAlertWithOk(title: .localized("Installation"), message: error.localizedDescription)
	}
}
