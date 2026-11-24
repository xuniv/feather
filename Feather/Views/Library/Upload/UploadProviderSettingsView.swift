import SwiftUI
import NimbleExtensions

@MainActor
struct UploadProviderSettingsView: View {
    @ObservedObject private var store = UploadProviderStore.shared
    @State private var editing = false
    @State private var sourceToReplace: URL?
    @State private var draftURL = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(store.sources) { source in
                    Button {
                        edit(source.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: source.url.absoluteString).font(.footnote)
                            if source.refreshFailed {
                                Text(.localized("Refresh failed. Using the last available list."))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let date = source.lastCheck {
                                Text(.localized("Checked %@", arguments: date.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(.localized("Remove"), role: .destructive) { store.removeSource(source.url) }
                    }
                }
                Button(.localized("Add Provider List URL"), systemImage: "plus") { edit(nil) }
                if !store.sources.contains(where: { $0.url == UploadProviderCatalog.defaultURL }) {
                    Button(.localized("Add Default List"), systemImage: "arrow.uturn.backward") {
                        save(UploadProviderCatalog.defaultURL.absoluteString, replacing: nil)
                    }
                }
            } header: {
                Text(.localized("Provider Lists"))
            } footer: {
                Text(.localized("Tap a URL to replace it. Add lists you trust: their rules determine where your IPA is uploaded. Feather checks each list every 7 days when the app is active."))
            }
            .disabled(store.isRefreshing)

            Section {
                if store.isRefreshing {
                    ProgressView(.localized("Refreshing Providers…"))
                } else {
                    Button(.localized("Refresh Now"), systemImage: "arrow.clockwise") {
                        Task { await store.refresh(force: true) }
                    }
                    .disabled(store.sources.isEmpty)
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(.localized("Upload Providers"))
        .alert(.localized("Provider List URL"), isPresented: $editing) {
            TextField("https://", text: $draftURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(.localized("Cancel"), role: .cancel) {}
            Button(.localized("Save")) { save(draftURL, replacing: sourceToReplace) }
        }
    }

    private func edit(_ url: URL?) {
        sourceToReplace = url
        draftURL = url?.absoluteString ?? ""
        editing = true
    }

    private func save(_ text: String, replacing original: URL?) {
        do {
            try store.saveSource(text, replacing: original)
            error = nil
            Task { await store.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
