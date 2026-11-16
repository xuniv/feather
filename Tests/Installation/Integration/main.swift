import Foundation
import Vapor
import NIOSSL

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let tls = try TLSConfiguration.makeServerConfiguration(
    certificateChain: NIOSSLCertificate.fromPEMFile(directory.appendingPathComponent("server.crt").path).map { .certificate($0) },
    privateKey: .privateKey(NIOSSLPrivateKey(file: directory.appendingPathComponent("server.pem").path, format: .pem))
)
let port = Int.random(in: 35000...45000)
let sessionID = UUID()
let metadata = InstallationTransport.Metadata(identifier: "com.example.test", name: "Test + & 한글", version: "42")
let server = InstallationHTTPServer()
let bytes = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
let package = directory.appendingPathComponent("fixture.ipa")
try bytes.write(to: package)

final class Stages {
    private let lock = NSLock()
    private var manifests = 0
    private var payloads = 0
    func record(_ stage: InstallationRequestHandler.Stage) {
        lock.lock()
        defer { lock.unlock() }
        switch stage {
        case .manifest: manifests += 1
        case .payload: payloads += 1
        case .delivered: break
        case .failed(let error): fatalError("Transfer failed: \(error)")
        }
    }
    var counts: (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (manifests, payloads)
    }
}
let stages = Stages()
func endpoint(_ host: String, _ path: String, http: Bool = false) -> URL {
    InstallationTransport.endpoint(host: host, port: port, path: path, http: http)
}
let manifestPath = "/\(sessionID).plist"
let payloadPath = "/\(sessionID).ipa"
func makeContent(http: Bool) throws -> InstallationRequestHandler {
    let manifest = endpoint("feather.localhost", manifestPath, http: http)
    return try InstallationRequestHandler(sessionID: sessionID, metadata: metadata, manifest: manifest,
        payload: endpoint("feather.localhost", payloadPath, http: http), selectedManifest: manifest, package: package,
        onStage: stages.record)
}

func request(_ url: URL, resolve: String? = nil, ca: Bool = true, arguments: [String] = []) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var options = ["curl", "--noproxy", "*", "--fail", "--silent", "--show-error", "--max-time", "8"]
    if ca { options += ["--cacert", directory.appendingPathComponent("authority.crt").path] }
    if let resolve { options += ["--resolve", resolve] }
    process.arguments = options + arguments + [url.absoluteString]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Request failed: \(url)") }
    return data
}

let content = try makeContent(http: false)
try server.start(port: port, tls: tls, localOnly: true, handler: content.respond)
let conflicting = InstallationHTTPServer()
do {
    try conflicting.start(port: port, tls: tls, localOnly: true, handler: content.respond)
    fatalError("Conflicting listener unexpectedly started")
} catch {}
let preflight = ["--header", "\(InstallationRequestHandler.preflightHeader): 1"]
let resolve = "feather.localhost:\(port):127.0.0.1"
let checkedManifest = try request(endpoint("feather.localhost", manifestPath), resolve: resolve, arguments: preflight)
assert(checkedManifest == content.manifestData)
_ = try request(endpoint("feather.localhost", manifestPath), resolve: resolve, arguments: ["--head"])
let head = try request(endpoint("feather.localhost", payloadPath), resolve: resolve, arguments: ["--head"])
assert(String(decoding: head, as: UTF8.self).lowercased().contains("content-length: \(bytes.count)"))
assert(stages.counts == (0, 0), "Preflight and HEAD must not dismiss Safari or start installation")

for (host, address) in [("feather.localhost", "127.0.0.1"), ("feather.localhost", "[::1]"), ("localhost", "127.0.0.1"), ("localhost", "[::1]"), ("127.0.0.1", "127.0.0.1")] {
    let resolve = "\(host):\(port):\(address)"
    let data = try request(endpoint(host, manifestPath), resolve: resolve)
    try InstallationTransport.validateManifest(data, metadata: metadata, payload: endpoint("feather.localhost", payloadPath))
    let page = try request(endpoint(host, "/install"), resolve: resolve)
    assert(String(decoding: page, as: UTF8.self).contains("<a id=\"install\">Install</a>"))
    // Simulate the system's confirmation pause and its metadata/range probes.
    Thread.sleep(forTimeInterval: 0.15)
    let beforeHEAD = stages.counts
    _ = try request(endpoint(host, payloadPath), resolve: resolve, arguments: ["--head"])
    assert(stages.counts == beforeHEAD)
    let partial = try request(endpoint(host, payloadPath), resolve: resolve, arguments: ["--range", "0-63"])
    assert(partial == bytes.prefix(64))
    let payload = try request(endpoint(host, payloadPath), resolve: resolve)
    assert(payload == bytes)
}
assert(stages.counts == (5, 10))
server.shutdown()
let httpContent = try makeContent(http: true)
try server.start(port: port, tls: nil, localOnly: false) { request in
    let headers: HTTPHeaders = ["Content-Range": "bytes 0-0/\(bytes.count)"]
    switch request.url.path {
    case "/probe-ignored-range": return Response(status: .ok, body: .init(data: bytes))
    case "/probe-wrong-byte": return Response(status: .partialContent, headers: headers, body: .init(data: Data([255])))
    case "/probe-too-long": return Response(status: .partialContent, headers: headers, body: .init(data: Data([0, 1])))
    case "/probe-empty": return Response(status: .partialContent, headers: headers)
    case "/probe-wrong-size": return Response(status: .partialContent, headers: ["Content-Range": "bytes 0-0/99"], body: .init(data: Data([0])))
    default: return httpContent.respond(to: request)
    }
}
let httpData = try request(endpoint("127.0.0.1", payloadPath, http: true), ca: false)
assert(httpData == bytes)

// Exercise the production preflight with Apple's Foundation URLSession, not
// just curl: this is the client API that rejected valid IPAs in 2.9.3.
final class ProbeOutcome: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); self.result = result; lock.unlock()
        done.signal()
    }
    func get() throws {
        lock.lock(); let result = self.result; lock.unlock()
        try result!.get()
    }
}
func swiftProbe(_ url: URL, sample: InstallationPayloadProbe.Sample) throws {
    let outcome = ProbeOutcome()
    Task.detached {
        do { try await InstallationPayloadProbe.check(url: url, sample: sample); outcome.finish(.success(())) }
        catch { outcome.finish(.failure(error)) }
    }
    guard outcome.done.wait(timeout: .now() + 20) == .success else { fatalError("URLSession probe timed out") }
    try outcome.get()
}
let sample = try InstallationPayloadProbe.Sample(file: package)
let beforeProbe = stages.counts
try swiftProbe(endpoint("127.0.0.1", payloadPath, http: true), sample: sample)
assert(stages.counts == beforeProbe, "URLSession preflight must not advance installer progress")
for path in ["/probe-ignored-range", "/probe-wrong-byte", "/probe-too-long", "/probe-empty", "/probe-wrong-size"] {
    do {
        try swiftProbe(endpoint("127.0.0.1", path, http: true), sample: sample)
        fatalError("Invalid payload probe accepted: \(path)")
    } catch {}
}
server.shutdown()
print("Production routes, Foundation URLSession one-byte preflight, invalid/oversized responses, HEAD isolation, ranged downloads, IPv4/IPv6 TLS and shutdown checks passed")
