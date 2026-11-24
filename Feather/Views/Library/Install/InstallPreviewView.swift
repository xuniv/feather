//
//  InstallPreview.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("Feather.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var _isOpeningInstallLink = false
	@State private var _showInstallLinkError = false
	@State private var _isPreviewActive = false
	@State private var _hasStarted = false
	@StateObject private var _activity = InstallationActivity()
	@State private var progressTask: Task<Void, Never>?
	
	var app: AppInfoPresentable
	private var original: OriginalIPAStore.Item? = nil
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
    init(original: OriginalIPAStore.Item) {
        self.app = original
        self.original = original
        self.isSharing = false
        let model = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1)
        self._viewModel = StateObject(wrappedValue: model)
        let metadata = InstallationTransport.Metadata(identifier: original.metadata.identifier,
            name: original.metadata.name, version: original.metadata.build)
        self._installer = StateObject(wrappedValue: ServerInstaller(metadata: metadata, viewModel: model))
    }

	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		ZStack {
			InstallProgressView(app: app, viewModel: viewModel)
			_status()
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.alert(.localized("Install"), isPresented: $_showInstallLinkError) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("iOS could not open the installation link. Tap Install to retry, or turn off Bypass Safari Web View in Installation settings."))
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .sendingPayload = newStatus {
					_isWebviewPresenting = false
				}

				if case .installing = newStatus {
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: app.identifier!,
							viewModel: viewModel
						)
					}
				}
				
			}
            switch newStatus {
            case .completed, .broken(_):
                progressTask?.cancel()
                progressTask = nil
                _activity.stop()
            default:
                break
            }
		}
		.onAppear {
			_isPreviewActive = true
			_install()
		}
		
		.onDisappear {
			// Safari and the system confirmation can cover this view while the
			// installer still needs its local server. Covering is not cancellation.
			if !_isWebviewPresenting {
				_isPreviewActive = false
				progressTask?.cancel()
				progressTask = nil
				_activity.stop()
			}
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.smooth, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if canRetryHandoff, !isSharing, _installationMethod == 0 {
				Button { openInstallHandoff() } label: {
					NBButton("Install", systemImage: "arrow.down.app", style: .text)
				}
				.disabled(_isOpeningInstallLink)
				.padding()
			}
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		guard !_hasStarted else { return }
		_hasStarted = true
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
		if !isSharing { _activity.start(retaining: installer) }
				
		Task.detached {
			do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                let packageUrl: URL
                if let original = await original {
                    // Preserve the entire ZIP, including its App Store signature,
                    // SC_Info/SINF license records and all nested bundles.
                    packageUrl = original.url
                    await MainActor.run { viewModel.packageProgress = 1 }
                } else {
                    try await handler.move()
                    packageUrl = try await handler.archive()
                }
				
				if await !isSharing {
					if await _installationMethod == 0 {
						try await installer.start(package: packageUrl)
						await MainActor.run {
							guard _isPreviewActive else { return }
							viewModel.status = .ready
							openInstallHandoff()
						}
					} else if await _installationMethod == 1 {
						let handler = await InstallationProxy(viewModel: viewModel)
						try await handler.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()
				
				await MainActor.run {
					viewModel.status = .broken(error)
					UIAlertController.showAlertWithOk(
						title: .localized("Install"),
						message: error.localizedDescription,
						action: {
							HeartbeatManager.shared.start(true)
							dismiss()
						}
					)
				}
			}
		}
	}

	@MainActor
	private func openInstallHandoff() {
		guard _isPreviewActive, canRetryHandoff, !_isOpeningInstallLink else { return }
		guard installer.bypassesWebView else {
			_isWebviewPresenting = true
			return
		}
		guard let url = installer.installationURL else { return }
		_isOpeningInstallLink = true
		Task { @MainActor in
			defer { _isOpeningInstallLink = false }
			guard _isPreviewActive else { return }
			let opened = await UIApplication.shared.open(url)
			if !opened, _isPreviewActive, canRetryHandoff { _showInstallLinkError = true }
		}
	}

	private var canRetryHandoff: Bool {
		switch viewModel.status {
		case .ready, .sendingManifest: true
		default: false
		}
	}

	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
