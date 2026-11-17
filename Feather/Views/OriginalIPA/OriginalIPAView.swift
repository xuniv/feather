import SwiftUI
import NimbleViews
import UniformTypeIdentifiers

struct OriginalIPAView: View {
    @StateObject private var store = OriginalIPAStore.shared
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    @State private var selected: OriginalIPAStore.Item?
    @State private var retained: OriginalIPAStore.Item?

    var body: some View {
        NBNavigationView(.localized("Original IPA")) {
            Form {
                Section {
                    Button { choosing = true } label: {
                        Label(.localized("Choose IPA File"), systemImage: "doc.badge.plus")
                    }
                    .disabled(busy)
                    if busy { ProgressView(.localized("Importing IPA…")) }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                } footer: {
                    Text(.localized("Import an IPA from ipatool or another tool. Original files are stored separately for up to 24 hours or until Feather restarts, with an 8 GiB total limit."))
                }
                Section {
                    Text(.localized("Install the original IPA, including DRM-protected apps, without resigning or modifying it. A valid original signature and any required App Store license are needed. This does not decrypt apps or acquire licenses."))
                }
                ForEach(store.items) { item in
                    Section {
                        Text(item.metadata.name).font(.headline)
                        Text(item.metadata.identifier).font(.caption).textSelection(.enabled)
                        Text("\(item.metadata.version) (\(item.metadata.build))")
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        Button(.localized("Install")) {
                            store.retain(item)
                            retained = item
                            selected = item
                        }
                        Button(.localized("Delete"), role: .destructive) { store.remove(item) }
                    }
                }
            }
            .sheet(item: $selected, onDismiss: {
                if let retained { store.release(retained) }
                retained = nil
            }) { item in
                InstallPreviewView(original: item)
                    .presentationDetents([.height(220)])
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.ipa]) { result in
                switch result {
                case .success(let url):
                    busy = true
                    Task {
                        defer { busy = false }
                        do { error = nil; try await store.add(url) }
                        catch { self.error = error.localizedDescription }
                    }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .onAppear { store.cleanup() }
        }
    }
}
