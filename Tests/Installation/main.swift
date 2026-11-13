import Foundation

func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(message) } catch {}
}

let metadata = InstallationTransport.Metadata(identifier: "com.example.test", name: "Test + & < > \" ' 한글 %?#/", version: "42.7")
// A 2.9.1 identity remains usable without rotating the already trusted root.
assert(InstallationTransport.compatibleLocalHosts(preferred: "feather.localhost", supports: { ["localhost", "127.0.0.1"].contains($0) }) == ["localhost", "127.0.0.1"])
assert(InstallationTransport.compatibleLocalHosts(preferred: "127.0.0.1", supports: { _ in true }) == ["127.0.0.1", "feather.localhost", "localhost"])
assert(InstallationTransport.compatibleLocalHosts(preferred: "external.example.org", supports: { _ in true }) == InstallationTransport.localHosts)
let payload = InstallationTransport.endpoint(host: "feather.localhost", port: 4567, path: "/test +&.ipa", http: false)
let hosted = try InstallationTransport.hostedManifest(server: "https://example.org/genPlist?custom=a%2Bb&name=stale", metadata: metadata, payload: payload)
let handoff = InstallationTransport.installationURL(manifest: hosted)
assert(handoff.absoluteString.hasPrefix("itms-services://?action=download-manifest&url="))
let outer = URLComponents(url: handoff, resolvingAgainstBaseURL: false)!.queryItems!
assert(outer.first { $0.name == "url" }!.value == hosted.absoluteString)
let fields = URLComponents(url: hosted, resolvingAgainstBaseURL: false)!.queryItems!
assert(fields.filter { $0.name == "name" }.count == 1)
assert(fields.first { $0.name == "name" }!.value == InstallationTransport.xmlText(metadata.name))
assert(fields.first { $0.name == "fetchurl" }!.value == InstallationTransport.xmlText(payload.absoluteString))
assert(fields.first { $0.name == "custom" }!.value == "a+b")
assert(!hosted.absoluteString.contains("+"))

// The upstream Rust service interpolates query values verbatim into XML.
// Recreate that response to verify URL decoding + XML decoding exactly once.
let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value!) })
let hostedXML = """
<?xml version="1.0"?><plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>\(values["fetchurl"]!)</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>\(values["bundleid"]!)</string><key>bundle-version</key><string>\(values["version"]!)</string><key>title</key><string>\(values["name"]!)</string></dict>
</dict></array></dict></plist>
"""
let hostedData = Data(hostedXML.utf8)
try InstallationTransport.validateManifest(hostedData, metadata: metadata, payload: payload)
let parsed = try PropertyListSerialization.propertyList(from: hostedData, format: nil) as! [String: Any]
let parsedMetadata = (parsed["items"] as! [[String: Any]])[0]["metadata"] as! [String: String]
assert(parsedMetadata["title"] == metadata.name)

for host in InstallationTransport.localHosts {
    for http in [false, true] {
        let package = InstallationTransport.endpoint(host: host, port: 5678, path: "/test.ipa", http: http)
        let icon = InstallationTransport.endpoint(host: host, port: 5678, path: "/icon.png", http: http)
        let manifest = InstallationTransport.manifest(metadata: metadata, payload: package, smallIcon: icon, largeIcon: icon)
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try InstallationTransport.validateManifest(data, metadata: metadata, payload: package)
        let link = InstallationTransport.installationURL(manifest: package)
        assert(URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!.last!.value == package.absoluteString)
    }
}
expectFailure("Wrong payload accepted") {
    try InstallationTransport.validateManifest(hostedData, metadata: metadata, payload: URL(string: "https://example.org/wrong.ipa")!)
}
expectFailure("Wrong app accepted") {
    try InstallationTransport.validateManifest(hostedData, metadata: .init(identifier: "other.app", name: "other", version: metadata.version), payload: payload)
}
expectFailure("Wrong build accepted") {
    try InstallationTransport.validateManifest(hostedData, metadata: .init(identifier: metadata.identifier, name: metadata.name, version: "999"), payload: payload)
}
for data in [Data(), Data("<html>Service error</html>".utf8), Data(repeating: 32, count: 1_048_577)] {
    expectFailure("Invalid hosted response accepted") { try InstallationTransport.validateManifest(data, metadata: metadata, payload: payload) }
}
for server in ["http://example.org/plist", "https://user:password@example.org/plist", "https://example.org/#fragment", "not a URL"] {
    expectFailure("Invalid server accepted") { _ = try InstallationTransport.hostedManifest(server: server, metadata: metadata, payload: payload) }
}
let html = InstallationTransport.handoffHTML(installationURL: handoff)
assert(html.contains("<a id=\"install\">Install</a>"))
assert(html.contains("document.getElementById('install').href=target"))
assert(html.contains("window.location.href=target"))
assert(!html.contains(metadata.name))
assert(InstallationServerMethod(rawValue: 0) == .localCA)
assert(InstallationServerMethod(rawValue: 1) == .hostedHTTP)
assert(InstallationServerMethod(rawValue: 2) == .publicTLS)
assert(InstallationServerMethod(rawValue: 3)!.usesLocalCA)
assert(InstallationServerMethod.hostedLocalCA.usesHostedManifest)
assert(!InstallationServerMethod.hostedLocalCA.usesHTTP)
print("Installation handoff, nested URL/XML encoding, hosted response validation and legacy mode checks passed")
