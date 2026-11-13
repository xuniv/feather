import Foundation
import Vapor
import NIOSSL

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let tls = try TLSConfiguration.makeServerConfiguration(
    certificateChain: NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent("server.crt").path).map { .certificate($0) },
    privateKey: .privateKey(NIOSSLPrivateKey(file: directory.appendingPathComponent("server.pem").path, format: .pem))
)
let port = Int.random(in: 35000...45000)
let metadata = InstallationTransport.Metadata(identifier: "com.example.test", name: "Test + & 한글", version: "42")
let server = InstallationHTTPServer()

func request(_ url: URL, resolve: String? = nil, ca: Bool = true) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var arguments = ["curl", "--noproxy", "*", "--fail", "--silent", "--show-error", "--max-time", "8"]
    if ca { arguments += ["--cacert", directory.appendingPathComponent("authority.crt").path] }
    if let resolve { arguments += ["--resolve", resolve] }
    process.arguments = arguments + [url.absoluteString]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Request failed: \(url)") }
    return data
}

func respond(_ request: Request, http: Bool) throws -> Response {
    let payload = InstallationTransport.endpoint(host: "feather.localhost", port: port, path: "/test.ipa", http: http)
    switch request.url.path {
    case "/test.plist":
        let icon = InstallationTransport.endpoint(host: "feather.localhost", port: port, path: "/icon.png", http: http)
        let manifest = InstallationTransport.manifest(metadata: metadata, payload: payload, smallIcon: icon, largeIcon: icon)
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        return Response(status: .ok, body: .init(data: data))
    case "/install":
        let manifest = InstallationTransport.endpoint(host: "feather.localhost", port: port, path: "/test.plist", http: http)
        return Response(status: .ok, body: .init(string: InstallationTransport.handoffHTML(installationURL: InstallationTransport.installationURL(manifest: manifest))))
    case "/test.ipa":
        return Response(status: .ok, body: .init(string: "fixture-payload"))
    default: return Response(status: .notFound)
    }
}

try server.start(port: port, tls: tls, localOnly: true) { try respond($0, http: false) }
for (host, address) in [("feather.localhost", "127.0.0.1"), ("feather.localhost", "[::1]"), ("localhost", "127.0.0.1"), ("localhost", "[::1]"), ("127.0.0.1", "127.0.0.1")] {
    let resolve = "\(host):\(port):\(address)"
    let manifestURL = InstallationTransport.endpoint(host: host, port: port, path: "/test.plist", http: false)
    let data = try request(manifestURL, resolve: resolve)
    let payload = InstallationTransport.endpoint(host: "feather.localhost", port: port, path: "/test.ipa", http: false)
    try InstallationTransport.validateManifest(data, metadata: metadata, payload: payload)
    let page = try request(InstallationTransport.endpoint(host: host, port: port, path: "/install", http: false), resolve: resolve)
    assert(String(decoding: page, as: UTF8.self).contains("<a id=\"install\">Install</a>"))
    let payloadData = try request(InstallationTransport.endpoint(host: host, port: port, path: "/test.ipa", http: false), resolve: resolve)
    assert(payloadData == Data("fixture-payload".utf8))
}
server.shutdown()
// Rebind after shutdown to verify lifecycle cleanup and the legacy HTTP listener.
try server.start(port: port, tls: nil, localOnly: false) { try respond($0, http: true) }
let httpData = try request(InstallationTransport.endpoint(host: "127.0.0.1", port: port, path: "/test.ipa", http: true), ca: false)
assert(httpData == Data("fixture-payload".utf8))
server.shutdown()
print("Production loopback listeners, IPv4/IPv6 TLS, manifests, handoff page, HTTP and shutdown checks passed")
