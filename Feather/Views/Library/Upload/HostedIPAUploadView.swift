import SwiftUI
import UIKit
import NimbleExtensions

@MainActor
struct HostedIPAUploadView: View {
    @Environment(\.dismiss) private var dismiss

    private let name: String
    private let appDirectory: URL?
    private let forInstallation: Bool

    @ObservedObject private var store = UploadProviderStore.shared
    @State private var archive: HostedIPAArchive?
    @State private var selectedProviderID: String?
    @State private var choices: [String: String] = [:]
    @State private var uploadedProvider: UploadProvider?
    @State private var operation: Task<Void, Never>?
    @State private var phase: Phase = .preparing
    @State private var progress: Double?
    @State private var message: String?
    @State private var failure: Failure?
    @State private var retryDates: [URL: Date] = [:]

    @State private var uploadedIPA: URL?
    @State private var uploadedManifest: URL?
    @State private var result: URL?
    @State private var copied = false

    private var provider: UploadProvider? {
        uploadedProvider ?? store.providers.first(where: { $0.id == selectedProviderID }) ?? store.preferredProvider
    }

    private var canUpload: Bool {
        guard let archive, let provider else { return false }
        guard retryAt.map({ $0 <= .now }) ?? true else { return false }
        return HostedIPAMultipart.accepts(size: archive.size, provider: provider, choices: configuredChoices(for: provider))
    }

    private var retryAt: Date? {
        provider.flatMap { retryDates[$0.upload.url] }
    }

    init(app: AppInfoPresentable) {
        name = app.name ?? .localized("Unknown")
        appDirectory = Storage.shared.getAppDirectory(for: app)
        forInstallation = app.isSigned
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(.localized("Name"), value: name)
                    if let archive {
                        LabeledContent(.localized("IPA Size"), value: ByteCountFormatter.string(fromByteCount: archive.size, countStyle: .file))
                    }
                    if phase == .preparing { ProgressView(.localized("Preparing IPA…")) }
                }

                if let result {
                    resultSection(result)
                } else {
                    providerSection
                    uploadSection
                }

                if let failure {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.phase.failureTitle).font(.headline)
                            Text(failure.host).font(.caption).foregroundStyle(.secondary)
                            Text(failure.detail).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                } else if let message {
                    Section {
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(forInstallation ? .localized("Upload for Install") : .localized("Upload for Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Done")) { dismiss() }
                        .disabled(operation != nil)
                }
            }
        }
        .interactiveDismissDisabled(operation != nil)
        .task { await prepare() }
        .task(id: retryAt) { await waitForRetry() }
        .onDisappear { operation?.cancel() }
    }

    private var providerSection: some View {
        Section {
            ForEach(store.providers) { candidate in
                let options = candidate.id == provider?.id ? configuredChoices(for: candidate) : [:]
                let fits = archive.map { HostedIPAMultipart.accepts(size: $0.size, provider: candidate, choices: options) } ?? true
                Button {
                    guard candidate.id != provider?.id else { return }
                    selectedProviderID = candidate.id
                    choices = [:]
                    failure = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.name)
                            Text(providerLimit(candidate, fits: fits))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if candidate.id == provider?.id {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(candidate.id == provider?.id ? .isSelected : [])
                }
                .disabled(!fits)
            }
            if let provider {
                LabeledContent(.localized("Upload Destination"), value: provider.upload.url.host ?? "")
                ForEach(provider.options) { option in
                    Picker(.localized(option.label), selection: optionBinding(option)) {
                        ForEach(option.choices) { choice in
                            Text(.localized(choice.label)).tag(choice.id)
                        }
                    }
                }
                if let note = provider.retentionNote {
                    Text(.localized(note)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                UploadProviderSettingsView()
            } label: {
                Label(.localized("Upload Providers"), systemImage: "slider.horizontal.3")
            }
        } header: {
            Text(.localized("Hosting Provider"))
        }
        .disabled(operation != nil || uploadedIPA != nil)
    }

    private func providerLimit(_ candidate: UploadProvider, fits: Bool) -> String {
        let size = ByteCountFormatter.string(fromByteCount: candidate.fileLimitBytes, countStyle: .file)
        return .localized(fits ? "Maximum %@" : "IPA exceeds %@", arguments: size)
    }

    private func optionBinding(_ option: UploadProvider.Option) -> Binding<String> {
        Binding {
            selectedChoice(option)
        } set: { value in
            choices[option.id] = value
        }
    }

    private func configuredChoices(for provider: UploadProvider) -> [String: String] {
        Dictionary(uniqueKeysWithValues: provider.options.map { ($0.id, selectedChoice($0)) })
    }

    private func selectedChoice(_ option: UploadProvider.Option) -> String {
        if let choice = choices[option.id], option.choices.contains(where: { $0.id == choice }) { return choice }
        return option.defaultChoice
    }

    private var uploadSection: some View {
        Section {
            if operation != nil {
                if let progress {
                    ProgressView(value: progress) { Text(phase.title) }
                } else {
                    ProgressView(phase.title)
                }
                Button(.localized("Cancel Upload"), role: .cancel) { operation?.cancel() }
            } else {
                Button(uploadedIPA == nil && failure == nil ? .localized("Upload") : .localized("Retry"),
                       systemImage: "arrow.up.circle", action: startUpload)
                    .disabled(!canUpload)
                if let retryAt, retryAt > .now {
                    Text(verbatim: .localized("Try again after %@.", arguments: retryAt.formatted(date: .abbreviated, time: .standard)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if uploadedIPA != nil {
                    Button(.localized("Change Upload Options")) {
                        uploadedProvider = nil
                        uploadedIPA = nil
                        uploadedManifest = nil
                        message = nil
                        failure = nil
                    }
                }
            }
        } footer: {
            Text(forInstallation
                 ? .localized("Anyone with the links can download the hosted files. The signed IPA can contain a provisioning profile listing registered devices. The install link works while both files are available.")
                 : .localized("Anyone with the link can download this IPA until the provider removes it."))
        }
    }

    private func resultSection(_ url: URL) -> some View {
        Section {
            Text(verbatim: url.absoluteString)
                .font(.footnote)
                .textSelection(.enabled)
            Button(copied ? .localized("Copied") : forInstallation ? .localized("Copy Install Link") : .localized("Copy IPA Link"),
                   systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = url.absoluteString
                copied = true
            }
            if forInstallation {
                Button(.localized("Open Install Link"), systemImage: "arrow.down.app") {
                    Task { @MainActor in
                        if !(await UIApplication.shared.open(url)) {
                            message = .localized("iOS could not open this install link. Copy it to share or open on another device.")
                        }
                    }
                }
            }
        } footer: {
            Text(forInstallation
                 ? .localized("The install link works while both hosted files are available.")
                 : .localized("Anyone with the link can download this IPA until the provider removes it."))
        }
    }

    private func prepare() async {
        guard archive == nil, phase == .preparing else { return }
        defer { phase = .ready }
        do {
            guard let appDirectory else { throw HostedIPAError.missingBundle }
            let prepared = try await HostedIPAArchive.prepare(app: appDirectory, forInstallation: forInstallation)
            try Task.checkCancellation()
            archive = prepared
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func startUpload() {
        guard operation == nil, canUpload, let archive, let provider else { return }
        let configuration = configuredChoices(for: provider)
        message = nil
        failure = nil
        operation = Task { @MainActor in
            defer {
                operation = nil
                phase = .ready
                progress = nil
            }
            do {
                let ipa: URL
                if let uploadedIPA {
                    ipa = uploadedIPA
                } else {
                    ipa = try await send(file: archive.file, kind: .ipa, provider: provider, choices: configuration)
                    uploadedProvider = provider
                    uploadedIPA = ipa
                }
                phase = .checkingIPA
                progress = nil
                try await HostedIPAUpload.checkIPA(ipa, provider: provider, localFile: archive.file, size: archive.size)
                guard let metadata = archive.metadata else {
                    result = ipa
                    return
                }

                let local = archive.file.deletingLastPathComponent().appendingPathComponent("install.plist")
                let data: Data
                let manifest: URL
                if let uploadedManifest {
                    phase = .checkingManifest
                    data = try Data(contentsOf: local)
                    manifest = uploadedManifest
                } else {
                    phase = .sendingManifest
                    data = try PropertyListSerialization.data(
                        fromPropertyList: InstallationTransport.manifest(metadata: metadata, payload: ipa),
                        format: .xml, options: 0)
                    try data.write(to: local, options: .atomic)
                    manifest = try await send(file: local, kind: .manifest, provider: provider, choices: configuration)
                    uploadedManifest = manifest
                }
                phase = .checkingManifest
                progress = nil
                try await HostedIPAUpload.checkManifest(manifest, provider: provider, expected: data)
                result = InstallationTransport.installationURL(manifest: manifest)
            } catch {
                guard !Task.isCancelled else { return }
                if let date = (error as? HostedIPAUpload.HTTPError)?.retryAt, date > .now {
                    retryDates[provider.upload.url] = date
                }
                let host = switch phase {
                case .checkingIPA: uploadedIPA?.host
                case .checkingManifest: uploadedManifest?.host
                default: provider.upload.url.host
                }
                failure = Failure(phase: phase, host: host ?? provider.name, detail: error.localizedDescription)
            }
        }
    }

    private func waitForRetry() async {
        guard let provider, let retryAt else { return }
        do {
            try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
        } catch { return }
        if retryDates[provider.upload.url] == retryAt {
            retryDates.removeValue(forKey: provider.upload.url)
        }
    }

    private func send(file: URL, kind: HostedIPAMultipart.FileKind, provider: UploadProvider,
                      choices: [String: String]) async throws -> URL {
        let uploadPhase: Phase = kind == .ipa ? .sendingIPA : .sendingManifest
        phase = uploadPhase
        progress = nil
        return try await HostedIPAUpload.send(file: file, kind: kind, provider: provider, choices: choices) { value in
            Task { @MainActor in
                if phase == uploadPhase { progress = value }
            }
        }
    }

    private enum Phase {
        case preparing, ready, sendingIPA, checkingIPA, sendingManifest, checkingManifest

        var title: String {
            switch self {
            case .preparing: .localized("Preparing IPA…")
            case .ready: .localized("Ready")
            case .sendingIPA: .localized("Uploading IPA…")
            case .checkingIPA: .localized("Checking IPA Link…")
            case .sendingManifest: .localized("Uploading Install Manifest…")
            case .checkingManifest: .localized("Checking Install Link…")
            }
        }

        var failureTitle: String {
            switch self {
            case .sendingIPA: .localized("IPA upload")
            case .checkingIPA: .localized("IPA download check")
            case .sendingManifest: .localized("Install manifest upload")
            case .checkingManifest: .localized("Install manifest download check")
            case .preparing, .ready: title
            }
        }
    }

    private struct Failure {
        let phase: Phase
        let host: String
        let detail: String
    }
}
