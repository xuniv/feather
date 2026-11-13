import SwiftUI
import NimbleViews

struct SigningCompatibilityView: View {
    @Binding var options: Options
    @State private var importingProfiles = false
    @State private var importingRuntime = false

    private func flag(_ key: WritableKeyPath<Options, Bool?>) -> Binding<Bool> {
        Binding(get: { options[keyPath: key] ?? false }, set: { options[keyPath: key] = $0 })
    }

    var body: some View {
        NBList(.localized("Compatibility & Patches")) {
            Section(.localized("Identity & Documents")) {
                Toggle(.localized("Duplicate App Mode"), isOn: flag(\.duplicateApp))
                Toggle(.localized("Hide App Icon"), isOn: flag(\.hideAppIcon))
                Toggle(.localized("Open Documents in Place"), isOn: flag(\.documentSupport))
            }
            Section {
                Toggle(.localized("Remove UISupportedDevices"), isOn: Binding(get: { options.removeSupportedDevices ?? true }, set: { options.removeSupportedDevices = $0 }))
                Toggle(.localized("Thin to arm64"), isOn: flag(\.thinToArm64))
                Toggle(.localized("Ignore Encryption Check"), isOn: flag(\.ignoreEncryption))
                Toggle(.localized("Enable JIT (get-task-allow)"), isOn: flag(\.enableJIT))
            } footer: {
                Text(.localized("Ignoring encryption does not decrypt binaries. JIT requires get-task-allow in every selected profile and a separate JIT activation method. Hiding the icon depends on iOS support."))
            }
            Section(.localized("Component Cleanup")) {
                Toggle(.localized("Remove Watch Apps"), isOn: flag(\.removeWatchApps))
                Toggle(.localized("Remove App Clips"), isOn: flag(\.removeAppClips))
                Toggle(.localized("Remove All Extensions"), isOn: flag(\.removeAllExtensions))
                Toggle(.localized("Remove Encrypted Extensions Only"), isOn: flag(\.removeEncryptedExtensions))
                    .disabled(options.removeAllExtensions == true)
            }
            Section {
                Picker(.localized("Substrate Runtime"), selection: Binding(get: { options.substrateRuntime ?? (options.experiment_replaceSubstrateWithEllekit ? .replaceWithElleKit : .automatic) }, set: { options.substrateRuntime = $0 })) {
                    ForEach(Options.SubstrateRuntime.allCases, id: \.self) { mode in Text(mode.localizedDescription).tag(mode) }
                }
                Picker(.localized("IPApatch"), selection: Binding(get: { options.ipaPatchMode ?? .off }, set: { options.ipaPatchMode = $0 })) {
                    ForEach(Options.IPAPatchMode.allCases, id: \.self) { mode in Text(mode.localizedDescription).tag(mode) }
                }
                NavigationLink { TweakLibraryView(options: $options, runtimeOnly: true) } label: {
                    Label(.localized("Choose from Tweak Folder"), systemImage: "folder")
                }
                Button(options.ipaPatchRuntime?.lastPathComponent ?? .localized("Select IPApatch Runtime")) { importingRuntime = true }
                if options.ipaPatchRuntime != nil {
                    Button(.localized("Clear Runtime"), role: .destructive) { options.ipaPatchRuntime = nil }
                }
            } footer: {
                Text(.localized("The patch system adds the selected runtime to the app and its extensions before signing. Keep runtime dylibs and other tweaks in your own Files folder; this option downloads no payloads."))
            }
            Section {
                ForEach(options.additionalProvisioningProfiles ?? [], id: \.self) { url in
                    Text(url.lastPathComponent).swipeActions {
                        Button(.localized("Remove"), role: .destructive) { options.additionalProvisioningProfiles?.removeAll { $0 == url } }
                    }
                }
                Button(.localized("Add Extension Provisioning Profiles")) { importingProfiles = true }
            } footer: {
                Text(.localized("Profiles must use the same signing certificate and team. Exact bundle IDs take priority over wildcard profiles. Custom entitlements apply to the main app; each extension keeps its own permitted entitlements."))
            }
        }
        .sheet(isPresented: $importingProfiles) {
            FileImporterRepresentableView(allowedContentTypes: [.data], allowsMultipleSelection: true, onDocumentsPicked: { urls in
                for url in urls {
                    FileManager.default.moveAndStore(url, with: "FeatherProvision") { stored in
                        if options.additionalProvisioningProfiles == nil { options.additionalProvisioningProfiles = [] }
                        options.additionalProvisioningProfiles?.append(stored)
                    }
                }
            }).ignoresSafeArea()
        }
        .sheet(isPresented: $importingRuntime) {
            FileImporterRepresentableView(allowedContentTypes: [.dylib], onDocumentsPicked: { urls in
                guard let url = urls.first else { return }
                FileManager.default.moveAndStore(url, with: "FeatherTweak") { stored in options.ipaPatchRuntime = stored }
            }).ignoresSafeArea()
        }
    }
}
