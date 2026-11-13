import Foundation

func expectFailure(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected failure") } catch { }
}

let profile: [String: Any] = [
    "TeamIdentifier": ["NEWTEAM123"], "ApplicationIdentifierPrefix": ["LEGACY1234"],
    "Entitlements": ["application-identifier": "LEGACY1234.com.example.*",
                     "com.apple.developer.team-identifier": "NEWTEAM123",
                     "keychain-access-groups": ["LEGACY1234.*"],
                     "get-task-allow": false,
                     "com.apple.developer.associated-domains": ["*"]]
]
let original: [String: Any] = [
    "application-identifier": "OLDPREFIX1.com.original.app.widget",
    "keychain-access-groups": ["OLDPREFIX1.com.original.app.shared"],
    "com.apple.developer.associated-domains": ["applinks:*.example.org"],
    "com.apple.developer.icloud-container-identifiers": ["iCloud.original"],
    "com.apple.security.application-groups": ["group.original"]
]
let result = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app.widget", original: original,
    oldRootID: "com.original.app", newRootID: "com.example.app")
assert(result.values["application-identifier"] as? String == "LEGACY1234.com.example.app.widget")
assert(result.values["com.apple.developer.team-identifier"] as? String == "NEWTEAM123")
assert(result.values["keychain-access-groups"] as? [String] == ["LEGACY1234.com.example.app.shared"])
assert(result.values["com.apple.developer.associated-domains"] as? [String] == ["applinks:*.example.org"])
assert(result.values["com.apple.developer.icloud-container-identifiers"] == nil)
assert(result.values["com.apple.security.application-groups"] == nil)
expectFailure { _ = try EntitlementPolicy.identity(profile: profile, bundleID: "com.other.app") }
expectFailure { _ = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app", original: [:], oldRootID: "", newRootID: "", enableJIT: true) }
expectFailure { _ = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app", original: [:], custom: ["keychain-access-groups": ["UNRELATED1.group"]], oldRootID: "", newRootID: "") }
var exact = profile
exact["Entitlements"] = ["application-identifier": "LEGACY1234.com.example.app", "keychain-access-groups": ["LEGACY1234.com.example.app"]]
expectFailure { _ = try EntitlementPolicy.identity(profile: exact, bundleID: "com.example.app.widget") }
assert(!EntitlementPolicy.matches("com.example.app", pattern: "com.*.app"))
let empty = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app", original: [:], oldRootID: "", newRootID: "")
assert(empty.values["keychain-access-groups"] as? [String] == ["LEGACY1234.com.example.app"])
assert(empty.values["com.apple.developer.associated-domains"] == nil)
var capabilities = profile
var allowed = capabilities["Entitlements"] as! [String: Any]
allowed["aps-environment"] = "development"
allowed["com.apple.security.application-groups"] = ["group.com.example.app.shared"]
capabilities["Entitlements"] = allowed
let migrated = try EntitlementPolicy.normalize(profile: capabilities, bundleID: "com.example.app.widget",
    original: ["aps-environment": "production", "com.apple.security.application-groups": ["group.com.original.app.shared"]],
    oldRootID: "com.original.app", newRootID: "com.example.app")
assert(migrated.values["aps-environment"] as? String == "development")
assert(migrated.values["com.apple.security.application-groups"] as? [String] == ["group.com.example.app.shared"])
let strippedBeta = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app",
    original: ["beta-reports-active": true, "platform-application": true], oldRootID: "", newRootID: "")
assert(strippedBeta.values["beta-reports-active"] == nil)
assert(strippedBeta.values["platform-application"] == nil)
assert(strippedBeta.warnings.count == 2)
expectFailure { _ = try EntitlementPolicy.normalize(profile: profile, bundleID: "com.example.app", original: [:],
    custom: ["beta-reports-active": true], oldRootID: "", newRootID: "") }
var betaProfile = profile
var betaAllowed = betaProfile["Entitlements"] as! [String: Any]
betaAllowed["beta-reports-active"] = true
betaProfile["Entitlements"] = betaAllowed
let authorizedBeta = try EntitlementPolicy.normalize(profile: betaProfile, bundleID: "com.example.app",
    original: ["beta-reports-active": true], oldRootID: "", newRootID: "")
assert(authorizedBeta.values["beta-reports-active"] as? Bool == true)
let adHocMain = EntitlementPolicy.adHoc(bundleID: "com.example.new", original: [
    "application-identifier": "OLDPREFIX1.com.example.old", "main-only": true,
    "keychain-access-groups": ["OLDPREFIX1.com.example.old.shared"], "platform-application": true
], custom: ["custom-main": true], oldRootID: "com.example.old", newRootID: "com.example.new")
let adHocWidget = EntitlementPolicy.adHoc(bundleID: "com.example.new.widget", original: [
    "application-identifier": "OLDPREFIX1.com.example.old.widget", "widget-only": true,
    "keychain-access-groups": ["OLDPREFIX1.*"], "com.apple.developer.associated-domains": ["applinks:*.example.org"]
], oldRootID: "com.example.old", newRootID: "com.example.new", enableJIT: true)
assert(adHocMain["application-identifier"] as? String == "OLDPREFIX1.com.example.new")
assert(adHocMain["keychain-access-groups"] as? [String] == ["OLDPREFIX1.com.example.new.shared"])
assert(adHocMain["platform-application"] as? Bool == true)
assert(adHocWidget["application-identifier"] as? String == "OLDPREFIX1.com.example.new.widget")
assert(adHocWidget["keychain-access-groups"] as? [String] == ["OLDPREFIX1.com.example.new.widget"])
assert(adHocWidget["main-only"] == nil && adHocWidget["custom-main"] == nil)
assert(adHocWidget["widget-only"] as? Bool == true)
assert(adHocWidget["get-task-allow"] as? Bool == true)
assert(adHocWidget["com.apple.developer.associated-domains"] as? [String] == ["applinks:*.example.org"])
assert(EntitlementPolicy.adHoc(bundleID: "com.example.app", original: [:], oldRootID: "", newRootID: "").isEmpty)

func words(_ values: [UInt32], little: Bool = true) -> Data {
    Data(values.flatMap { value -> [UInt8] in
        let bytes = [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
        return little ? bytes : Array(bytes.reversed())
    })
}
let plain = words([0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0])
let encrypted = words([0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0, 0x2c, 24, 0, 0, 1, 0])
let plainEncrypted = try MachOCompatibility.encrypted(plain)
assert(!plainEncrypted)
let isEncrypted = try MachOCompatibility.encrypted(encrypted)
assert(isEncrypted)
var fat = words([0xcafebabe, 2, 0x01000007, 3, 48, 32, 0, 0x0100000c, 0, 80, 32, 0], little: false)
fat += words([0xfeedfacf, 0x01000007, 3, 2, 0, 0, 0, 0])
fat += plain
let thinned = try MachOCompatibility.arm64(fat)
assert(thinned == plain)
expectFailure { _ = try MachOCompatibility.slices(words([0xcafebabe, 0xffffffff], little: false)) }
expectFailure { _ = try MachOCompatibility.encrypted(words([0xfeedfacf, 0x0100000c, 0, 2, 1, 8, 0, 0, 0x2c, 8])) }
expectFailure { _ = try MachOCompatibility.slices(words([0xcafebabe, 1, 0x0100000c, 0, 0xfffffff0, 32, 0], little: false)) }
print("Entitlement and Mach-O regression checks passed")
