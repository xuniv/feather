import Foundation

/// Provisioning is an allowlist; a profile's wildcard is never an app identity.
enum EntitlementPolicy {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func matches(_ value: String, pattern: String) -> Bool {
        guard let star = pattern.firstIndex(of: "*") else { return value == pattern }
        guard star == pattern.index(before: pattern.endIndex) else { return false }
        return value.hasPrefix(String(pattern[..<star]))
    }

    static func permits(_ value: Any, by allowed: Any) -> Bool {
        if let values = value as? [Any], let choices = allowed as? [Any] {
            return values.allSatisfy { value in choices.contains { permits(value, by: $0) } }
        }
        if let value = value as? String, let pattern = allowed as? String {
            return matches(value, pattern: pattern)
        }
        if let value = value as? [String: Any], let allowed = allowed as? [String: Any] {
            return value.allSatisfy { key, item in allowed[key].map { permits(item, by: $0) } ?? false }
        }
        return (value as? NSObject)?.isEqual(allowed) == true
    }

    static func identity(profile: [String: Any], bundleID: String) throws -> (appID: String, team: String) {
        guard let entitlements = profile["Entitlements"] as? [String: Any],
              let pattern = entitlements["application-identifier"] as? String,
              let dot = pattern.firstIndex(of: "."),
              let team = (profile["TeamIdentifier"] as? [String])?.first,
              !team.isEmpty, !bundleID.isEmpty, !bundleID.contains("*") else {
            throw Failure(message: "Invalid provisioning identity for \(bundleID).")
        }
        let prefix = String(pattern[..<dot])
        let appID = prefix + "." + bundleID
        guard matches(appID, pattern: pattern) else {
            throw Failure(message: "The provisioning profile does not allow \(bundleID). Add a matching profile for this app or extension.")
        }
        return (appID, team)
    }

    static func normalize(profile: [String: Any], bundleID: String, original: [String: Any],
                          custom: [String: Any] = [:], oldRootID: String, newRootID: String,
                          enableJIT: Bool = false) throws -> (values: [String: Any], warnings: [String]) {
        let identity = try identity(profile: profile, bundleID: bundleID)
        let allowed = profile["Entitlements"] as? [String: Any] ?? [:]
        var result: [String: Any] = [
            "application-identifier": identity.appID,
            "com.apple.developer.team-identifier": identity.team
        ]
        var warnings: [String] = []
        let identityKeys: Set<String> = ["application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier"]
        let oldPrefix = (original["application-identifier"] as? String)?.split(separator: ".").first.map(String.init)
        let prefix = String(identity.appID.prefix { $0 != "." })

        func remapGroup(_ group: String) -> String {
            var value = group
            if let oldPrefix, value.hasPrefix(oldPrefix + ".") {
                value = prefix + value.dropFirst(oldPrefix.count)
            }
            if oldRootID != newRootID, !oldRootID.isEmpty {
                let old = prefix + "." + oldRootID
                if value == old || value.hasPrefix(old + ".") {
                    value = prefix + "." + newRootID + value.dropFirst(old.count)
                }
            }
            if value == prefix + ".*" { value = identity.appID }
            return value
        }

        var requested = original.merging(custom) { _, custom in custom }
        if enableJIT { requested["get-task-allow"] = true }
        for (key, input) in requested where !identityKeys.contains(key) {
            var value = input
            if key == "keychain-access-groups", let groups = input as? [String] {
                value = groups.map(remapGroup)
            }
            let containerKeys: Set<String> = ["com.apple.security.application-groups", "com.apple.developer.icloud-container-identifiers", "com.apple.developer.ubiquity-container-identifiers"]
            if containerKeys.contains(key), let groups = input as? [String], !oldRootID.isEmpty {
                value = groups.map { group -> String in
                    for prefix in ["group.", "iCloud."] {
                        let old = prefix + oldRootID
                        if group == old || group.hasPrefix(old + ".") {
                            let candidate = prefix + newRootID + group.dropFirst(old.count)
                            if let permission = allowed[key], permits([candidate], by: permission) { return candidate }
                        }
                    }
                    return group
                }
            }
            if let permission = allowed[key] {
                if permits(value, by: permission) {
                    result[key] = value
                } else if custom[key] != nil || (key == "get-task-allow" && enableJIT) {
                    throw Failure(message: "\(bundleID): the profile does not permit entitlement \(key).")
                } else if ["aps-environment", "com.apple.developer.icloud-container-environment"].contains(key),
                          let environment = permission as? String, !environment.contains("*") {
                    // Environment values come from the selected profile, not the old signer.
                    result[key] = environment
                } else {
                    warnings.append("\(bundleID): removed unsupported \(key).")
                }
            } else if key.hasPrefix("com.apple.developer.") || key.hasPrefix("com.apple.private.") || key == "com.apple.security.application-groups" || key == "aps-environment" || key == "get-task-allow" || key == "keychain-access-groups" {
                if custom[key] != nil || (key == "get-task-allow" && enableJIT) {
                    throw Failure(message: "\(bundleID): entitlement \(key) needs a provisioning profile with that capability.")
                }
                warnings.append("\(bundleID): removed unprovisioned \(key).")
            } else {
                result[key] = value
                if custom[key] != nil { warnings.append("\(bundleID): custom entitlement \(key) is not declared by the profile.") }
            }
        }
        // Profile-only capabilities must not be copied as wildcard grants.
        if result["get-task-allow"] == nil, let permission = allowed["get-task-allow"] { result["get-task-allow"] = permission }
        if result["keychain-access-groups"] == nil,
           let groups = allowed["keychain-access-groups"] as? [String],
           groups.contains(where: { matches(identity.appID, pattern: $0) }) {
            result["keychain-access-groups"] = [identity.appID]
        }
        // Identity aliases, if present in the input, must agree too.
        if original["com.apple.application-identifier"] != nil || custom["com.apple.application-identifier"] != nil {
            result["com.apple.application-identifier"] = identity.appID
        }
        return (result, warnings)
    }
}
