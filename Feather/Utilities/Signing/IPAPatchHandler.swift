import Foundation
import Zsign

/// IPApatch-compatible load paths. Runtime selection is explicit and opt-in.
enum IPAPatchHandler {
    static func apply(to app: URL, options: Options) throws {
        let mode = options.ipaPatchMode ?? .off
        guard mode != .off else { return }
        guard let runtime = options.ipaPatchRuntime, runtime.pathExtension == "dylib" else {
            throw EntitlementPolicy.Failure(message: "Select an IPApatch-compatible runtime dylib before enabling IPApatch.")
        }
        let manager = FileManager.default
        let frameworkDirectory = app.appendingPathComponent("Frameworks")
        try manager.createDirectory(at: frameworkDirectory, withIntermediateDirectories: true)
        let target = frameworkDirectory.appendingPathComponent("FeatherIPAPatch.dylib")
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.copyItem(at: runtime, to: target)
        var bundles = mode == .appAndExtensions ? [app] : []
        if let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if url.pathExtension == "appex" { bundles.append(url) }
            }
        }
        for bundle in bundles {
            guard let executable = Bundle(url: bundle)?.executableURL else { throw SigningFileHandlerError.appNotFound }
            let depth = bundle == app ? 0 : bundle.pathComponents.count - app.pathComponents.count
            let path = "@executable_path/" + String(repeating: "../", count: depth) + "Frameworks/FeatherIPAPatch.dylib"
            if !Zsign.listDylibs(appExecutable: executable.path).contains(path),
               !Zsign.injectDyLib(appExecutable: executable.path, with: path, weak: true) {
                throw EntitlementPolicy.Failure(message: "IPApatch injection failed for \(bundle.lastPathComponent).")
            }
        }
    }
}
