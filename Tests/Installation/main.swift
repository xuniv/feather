import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
assert(handoff.absoluteString.hasPrefix("itms-services://?action=download-manifest&url=https%3A%2F%2F"))
let outer = URLComponents(url: handoff, resolvingAgainstBaseURL: false)!.queryItems!
assert(outer.first { $0.name == "url" }!.value == hosted.absoluteString)
let fields = URLComponents(url: hosted, resolvingAgainstBaseURL: false)!.queryItems!
assert(fields.filter { $0.name == "name" }.count == 1)
assert(fields.first { $0.name == "name" }!.value == InstallationTransport.xmlText(metadata.name))
assert(fields.first { $0.name == "fetchurl" }!.value == InstallationTransport.xmlText(payload.absoluteString))
assert(fields.first { $0.name == "custom" }!.value == "a+b")
assert(!hosted.absoluteString.contains("+"))

// The new default worker escapes XML itself, unlike the legacy custom server.
let payloadWithQuery = URL(string: "http://127.0.0.1:4567/test.ipa?a=1&b=2")!
let worker = try InstallationTransport.hostedManifest(server: InstallationTransport.defaultHostedServer,
    metadata: metadata, payload: payloadWithQuery)
let workerFields = URLComponents(url: worker, resolvingAgainstBaseURL: false)!.queryItems!
assert(workerFields.first { $0.name == "name" }!.value == metadata.name)
assert(workerFields.first { $0.name == "fetchurl" }!.value == payloadWithQuery.absoluteString)
assert(!worker.absoluteString.contains("+"))

// The upstream Rust service interpolates query values verbatim into XML.
// Recreate that response to verify URL decoding + XML decoding exactly once.
let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value!) })
let hostedXML = """
<?xml version="1.0"?><plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>\(values["fetchurl"]!)</string></dict></array>
<key>metadata</key><dict><key>kind</key><string>software</string><key>bundle-identifier</key><string>\(values["bundleid"]!)</string><key>bundle-version</key><string>\(values["version"]!)</string><key>title</key><string>\(values["name"]!)</string></dict>
</dict></array></dict></plist>
"""
let hostedData = Data(hostedXML.utf8)
try InstallationTransport.validateManifest(hostedData, metadata: metadata, payload: payload)
let parsed = try PropertyListSerialization.propertyList(from: hostedData, format: nil) as! [String: Any]
let localManifest = InstallationTransport.manifest(metadata: metadata, payload: payload)
assert(NSDictionary(dictionary: localManifest).isEqual(to: parsed))
let assets = ((localManifest["items"] as! [[String: Any]])[0]["assets"] as! [[String: String]])
assert(assets.count == 1 && assets[0]["kind"] == "software-package")
let parsedMetadata = (parsed["items"] as! [[String: Any]])[0]["metadata"] as! [String: String]
assert(parsedMetadata["title"] == metadata.name)

for host in InstallationTransport.localHosts {
    for http in [false, true] {
        let package = InstallationTransport.endpoint(host: host, port: 5678, path: "/test.ipa", http: http)
        let manifest = InstallationTransport.manifest(metadata: metadata, payload: package)
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

let preferencesSuite = "InstallationHandoffTests.\(UUID())"
let preferences = UserDefaults(suiteName: preferencesSuite)!
defer { preferences.removePersistentDomain(forName: preferencesSuite) }
assert(InstallationServerMethod.defaultMethod == .localCA)
assert(InstallationTransport.preferredLocalHost == "feather.localhost")
assert(InstallationServerMethod.localCA.bypassesWebView(defaults: preferences))
preferences.set(false, forKey: InstallationTransport.webViewBypassKey)
assert(!InstallationServerMethod.localCA.bypassesWebView(defaults: preferences))
preferences.set(true, forKey: InstallationTransport.webViewBypassKey)
for method in InstallationServerMethod.allCases {
    assert(method.bypassesWebView(defaults: preferences) == (method == .localCA))
}
let offlineManifest = InstallationTransport.endpoint(host: InstallationTransport.preferredLocalHost,
    port: 4567, path: "/test.plist", http: false)
let directLink = InstallationTransport.installationURL(manifest: offlineManifest)
assert(directLink.absoluteString == "itms-services://?action=download-manifest&url=https%3A%2F%2Ffeather.localhost%3A4567%2Ftest.plist")
print("Installation handoff, nested URL/XML encoding, hosted response validation and legacy mode checks passed")

// Body-length metadata is not evidence that the IPA is missing. A ranged GET
// can legitimately have an unknown expectedContentLength (e.g. chunked data).
let probeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: probeDirectory) }
let probeFile = probeDirectory.appendingPathComponent("sample.ipa")
try Data([0x50, 0x4b, 3, 4]).write(to: probeFile)
let sample = try InstallationPayloadProbe.Sample(file: probeFile)
let probeURL = URL(string: "http://127.0.0.1:4567/sample.ipa")!
let probeRequest = InstallationPayloadProbe.request(url: probeURL)
assert(probeRequest.httpMethod == "GET")
assert(probeRequest.value(forHTTPHeaderField: "Range") == "bytes=0-0")
assert(probeRequest.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
assert(probeRequest.value(forHTTPHeaderField: InstallationTransport.preflightHeader) == "1")
let unknownLength = HTTPURLResponse(url: probeURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 0-0/4"])!
assert(unknownLength.expectedContentLength <= 0)
try InstallationPayloadProbe.validateResponse(unknownLength, sample: sample)
try InstallationPayloadProbe.validateBody(Data([0x50]), sample: sample)
for status in [200, 204, 404, 500] {
    expectFailure("Invalid range status accepted") {
        try InstallationPayloadProbe.validateResponse(HTTPURLResponse(url: probeURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes 0-0/4"])!, sample: sample)
    }
}
for range in ["bytes 0-1/4", "bytes 0-0/99", "bytes 0-0/*", "invalid"] {
    expectFailure("Invalid range accepted") {
        try InstallationPayloadProbe.validateResponse(HTTPURLResponse(url: probeURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": range])!, sample: sample)
    }
}
for body in [Data(), Data([0]), Data([0x50, 0x4b])] {
    expectFailure("Invalid probe bytes accepted") { try InstallationPayloadProbe.validateBody(body, sample: sample) }
}
try Data().write(to: probeFile)
expectFailure("Empty IPA accepted") { _ = try InstallationPayloadProbe.Sample(file: probeFile) }
expectFailure("Missing IPA accepted") { _ = try InstallationPayloadProbe.Sample(file: probeDirectory.appendingPathComponent("missing.ipa")) }
print("One-byte IPA probe checks passed, including unknown response-body length")
