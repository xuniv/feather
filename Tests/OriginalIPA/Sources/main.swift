import Foundation
import ZIPFoundation

func expectFailure(_ body: () throws -> Void) {
    do { try body(); fatalError("Accepted malformed original IPA") } catch {}
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let info: [String: Any] = ["CFBundleIdentifier": "example.original", "CFBundleVersion": "42",
    "CFBundleShortVersionString": "1.2", "CFBundleDisplayName": "Original & IPA", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
func fixture(_ name: String, entries: [(String, Data)]) throws -> URL {
    let file = root.appendingPathComponent(name).appendingPathExtension("ipa")
    let archive = try Archive(url: file, accessMode: .create)
    for (path, data) in entries {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
        }
    }
    return file
}
for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
    let file = try fixture(UUID().uuidString, entries: [
        ("Payload/Original.app/Info.plist", plist),
        ("Payload/Original.app/SC_Info/Original.sinf", Data("opaque license record".utf8)),
        ("Payload/Original.app/_CodeSignature/CodeResources", Data("opaque original signature".utf8)),
        ("Payload/Original.app/Original", Data([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3])),
        ("Payload/Original.app/PlugIns/Widget.appex/Info.plist", plist)])
    let before = try Data(contentsOf: file)
    let metadata = try OriginalIPAMetadata.read(file)
    precondition(metadata.identifier == "example.original" && metadata.build == "42" && metadata.version == "1.2")
    precondition(metadata.name == "Original & IPA")
    let after = try Data(contentsOf: file)
    precondition(before == after, "Original signed/encrypted archive was modified")
}
let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
for entries: [(String, Data)] in [[], [("../Payload/X.app/Info.plist", plist)],
    [("Payload/X.app/Info.plist", plist), ("Payload/Y.app/Info.plist", plist)],
    [("Payload/X.app/Info.plist", Data(repeating: 0, count: 1024 * 1024 + 1))],
    [("Payload/X.app/Info.plist", Data("not a plist".utf8))]] {
    let file = try fixture(UUID().uuidString, entries: entries)
    expectFailure { _ = try OriginalIPAMetadata.read(file) }
}
for (key, value) in [("CFBundleIdentifier", "bad/identifier"), ("CFBundleVersion", ""), ("CFBundleDisplayName", "\u{0}")] {
    var invalid = info; invalid[key] = value
    if key == "CFBundleDisplayName" { invalid["CFBundleIdentifier"] = "\u{0}" }
    expectFailure { _ = try OriginalIPAMetadata.parse(invalid) }
}
var tv = info; tv["CFBundleSupportedPlatforms"] = ["AppleTVOS"]
expectFailure { _ = try OriginalIPAMetadata.parse(tv) }
print("Original IPA metadata and byte-preservation checks passed")
try await checkHostedIPA(catalogFile: URL(fileURLWithPath: CommandLine.arguments[1]))
