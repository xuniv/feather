import Foundation
import ZIPFoundation

/// Reads one bounded plist in place. No extraction, signature edits or DRM changes.
/// The original-package workflow follows xuniv/asspp's ImportedIPAStore design.
struct OriginalIPAMetadata: Sendable {
    let identifier: String
    let name: String
    let build: String
    let version: String

    struct Failure: LocalizedError {
        var errorDescription: String? { "Choose an iOS IPA containing one main app with a valid bundle identifier and build version." }
    }

    static func read(_ url: URL) throws -> Self {
        let archive = try Archive(url: url, accessMode: .read)
        var main: Entry?
        for (index, entry) in archive.enumerated() {
            guard index < 100_000 else { throw Failure() }
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"),
               parts[1] != ".app", parts[2] == "Info.plist" {
                guard main == nil, entry.type == .file, entry.uncompressedSize <= 1024 * 1024 else { throw Failure() }
                main = entry
            }
        }
        guard let main else { throw Failure() }
        var data = Data()
        _ = try archive.extract(main) { chunk in
            guard chunk.count <= 1024 * 1024 - data.count else { throw Failure() }
            data.append(chunk)
        }
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure() }
        return try parse(info)
    }

    static func parse(_ info: [String: Any]) throws -> Self {
        func text(_ key: String, limit: Int = 255) -> String? {
            guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= limit, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        guard let identifier = text("CFBundleIdentifier"),
              identifier.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$"#, options: .regularExpression) != nil,
              let build = text("CFBundleVersion", limit: 128),
              (info["CFBundleSupportedPlatforms"] as? [String] ?? []).contains("iPhoneOS") ||
                (info["DTPlatformName"] as? String)?.lowercased() == "iphoneos" else { throw Failure() }
        return .init(identifier: identifier,
                     name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? identifier,
                     build: build, version: text("CFBundleShortVersionString", limit: 128) ?? build)
    }
}
