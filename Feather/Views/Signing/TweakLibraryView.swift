import SwiftUI
import NimbleViews

/// The folder is populated by the user in Files; the app ships no catalog.
struct TweakLibraryView: View {
    @Binding var options: Options
    var runtimeOnly = false
    @State private var files: [URL] = []
    @State private var errorMessage: String?

    private var directory: URL { URL.documentsDirectory.appendingPathComponent("Tweaks", isDirectory: true) }

    var body: some View {
        NBList(.localized("Tweak Folder")) {
            Section {
                if files.isEmpty { Text(.localized("No files chosen. Add .deb or .dylib files to Documents/Tweaks in Files, then refresh.")) }
                ForEach(files, id: \.self) { file in
                    Button {
                        if runtimeOnly { options.ipaPatchRuntime = file }
                        else if let index = options.injectionFiles.firstIndex(of: file) { options.injectionFiles.remove(at: index) }
                        else { options.injectionFiles.append(file) }
                    } label: {
                        HStack {
                            Text(file.lastPathComponent)
                            Spacer()
                            if runtimeOnly ? options.ipaPatchRuntime == file : options.injectionFiles.contains(file) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } footer: {
                Text(.localized("Selected files are copied into the working app during signing. Originals stay in Documents/Tweaks for reuse. IPApatch runtime selection accepts dylibs only."))
            }
            Section {
                Button(.localized("Refresh"), systemImage: "arrow.clockwise") { refresh() }
                Button(.localized("Open Tweak Folder"), systemImage: "folder") {
                    if let url = directory.toSharedDocumentsURL() { UIApplication.shared.open(url) }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)
                .filter { url in
                    (runtimeOnly ? ["dylib"] : ["deb", "dylib"]).contains(url.pathExtension.lowercased()) &&
                    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
