import Foundation
import ZsignC
import OSLog

enum BundleSigningPlan {
    static func make(app: URL, profileURL: URL, options: Options, directory: URL) throws -> (settings: [String: [String: String]], warnings: [String]) {
        let manager = FileManager.default
        let profiles = try ([profileURL] + (options.additionalProvisioningProfiles ?? [])).map { url -> (URL, [String: Any]) in
            guard let data = ReadProvisioningProfile(url.path),
                  let profile = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let expiry = profile["ExpirationDate"] as? Date, expiry > Date() else {
                throw EntitlementPolicy.Failure(message: "Invalid or expired provisioning profile: \(url.lastPathComponent)")
            }
            return (url, profile)
        }
        let root = try info(app)
        guard let rootID = root["CFBundleIdentifier"] as? String else { throw SigningFileHandlerError.infoPlistNotFound }
        let primaryTeam = try EntitlementPolicy.identity(profile: profiles[0].1, bundleID: rootID).team
        var custom: [String: Any] = [:]
        if let file = options.appEntitlementsFile {
            guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
                throw EntitlementPolicy.Failure(message: "The custom entitlement file must contain a plist dictionary.")
            }
            custom = values
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var bundles = [app]
        if let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if ["app", "appex"].contains(url.pathExtension) { bundles.append(url) }
            }
        }
        var settings: [String: [String: String]] = [:]
        var warnings: [String] = []
        for bundle in bundles {
            let plist = try info(bundle)
            guard let bundleID = plist["CFBundleIdentifier"] as? String,
                  let executable = plist["CFBundleExecutable"] as? String,
                  !executable.contains("/"), executable != ".." else { throw SigningFileHandlerError.infoPlistNotFound }
            let candidates = profiles.filter { (try? EntitlementPolicy.identity(profile: $0.1, bundleID: bundleID))?.team == primaryTeam }
            // An exact profile wins over a wildcard; otherwise choose the longest prefix.
            let selected = candidates.max { lhs, rhs in
                func score(_ profile: [String: Any]) -> Int {
                    let pattern = (profile["Entitlements"] as? [String: Any])?["application-identifier"] as? String ?? ""
                    return pattern.contains("*") ? pattern.count : Int.max
                }
                return score(lhs.1) < score(rhs.1)
            }
            guard let selected else {
                throw EntitlementPolicy.Failure(message: "No profile from the signing team permits \(bundleID). Add a matching extension profile.")
            }
            var original: [String: Any] = [:]
            if options.preserveBundleEntitlements != false,
               let data = LCGetMachOEntitlements(bundle.appendingPathComponent(executable).path),
               let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { original = values }
            let normalized = try EntitlementPolicy.normalize(profile: selected.1, bundleID: bundleID, original: original,
                custom: bundle == app ? custom : [:], oldRootID: options.originalAppIdentifier ?? rootID,
                newRootID: rootID, enableJIT: options.enableJIT == true)
            warnings.append(contentsOf: normalized.warnings)
            for warning in normalized.warnings { Logger.signing.warning("\(warning, privacy: .public)") }
            let file = directory.appendingPathComponent(UUID().uuidString + ".plist")
            try PropertyListSerialization.data(fromPropertyList: normalized.values, format: .xml, options: 0).write(to: file, options: .atomic)
            let path = bundle == app ? "/" : String(bundle.path.dropFirst(app.path.count + 1))
            settings[path] = ["profile": selected.0.path, "entitlements": file.path]
        }
        return (settings, warnings)
    }

    private static func info(_ bundle: URL) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] else {
            throw SigningFileHandlerError.infoPlistNotFound
        }
        return plist
    }
}
