import Foundation

enum AppCompatibility {
    static func removeComponents(at app: URL, options: Options) throws {
        let manager = FileManager.default
        for (name, enabled) in [("Watch", options.removeWatchApps), ("AppClips", options.removeAppClips)] where enabled == true {
            let url = app.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        guard let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard url.pathExtension == "appex" else { continue }
            var remove = options.removeAllExtensions == true
            if !remove, options.removeEncryptedExtensions == true,
               let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
               let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
                remove = try MachOCompatibility.encrypted(Data(contentsOf: url.appendingPathComponent(executable), options: .mappedIfSafe))
            }
            if remove { enumerator.skipDescendants(); try manager.removeItem(at: url) }
        }
    }

    static func patchBinaries(at app: URL, options: Options) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            // Read only a magic word for resources, rather than mapping every asset.
            let handle = try FileHandle(forReadingFrom: file)
            let magic = try handle.read(upToCount: 4) ?? Data()
            try handle.close()
            guard magic.count == 4,
                  [Data([0xfe,0xed,0xfa,0xce]), Data([0xce,0xfa,0xed,0xfe]), Data([0xfe,0xed,0xfa,0xcf]), Data([0xcf,0xfa,0xed,0xfe]),
                   Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca]), Data([0xca,0xfe,0xba,0xbf]), Data([0xbf,0xba,0xfe,0xca])].contains(magic) else { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            if options.ignoreEncryption != true, try MachOCompatibility.encrypted(data) {
                throw EntitlementPolicy.Failure(message: "Encrypted binary: \(file.lastPathComponent). Use a decrypted IPA or remove encrypted extensions. Ignoring this check does not decrypt an app.")
            }
            if options.thinToArm64 == true {
                let thinned = try MachOCompatibility.arm64(data)
                if thinned != data {
                    let attributes = try manager.attributesOfItem(atPath: file.path)
                    try thinned.write(to: file, options: .atomic)
                    if let mode = attributes[.posixPermissions] { try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
                }
            }
        }
    }
}
