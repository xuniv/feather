import Foundation

enum InstallationServerMethod: Int, CaseIterable {
    case localCA = 0
    case hostedHTTP = 1
    case publicTLS = 2
    case hostedLocalCA = 3

    static let defaultMethod: Self = .localCA
    var usesLocalCA: Bool { self == .localCA || self == .hostedLocalCA }
    var usesHostedManifest: Bool { self == .hostedHTTP || self == .hostedLocalCA }
    var usesHTTP: Bool { self == .hostedHTTP }
    var supportsWebViewBypass: Bool { self == .localCA }

    func bypassesWebView(defaults: UserDefaults) -> Bool {
        supportsWebViewBypass &&
            (defaults.object(forKey: InstallationTransport.webViewBypassKey) as? Bool ?? InstallationTransport.defaultWebViewBypass)
    }

    var title: String {
        switch self {
        case .localCA: "Local CA (Offline)"
        case .hostedHTTP: "Hosted Plist (HTTP)"
        case .publicTLS: "Public TLS"
        case .hostedLocalCA: "Hosted Plist + Local CA"
        }
    }
}

/// Keep each URL as a URL until its query value is encoded by the next layer.
enum InstallationTransport {
    static let preflightHeader = "X-Feather-Preflight"
    static let defaultHostedServer = "https://api.palera.in/genPlist"
    static let webViewBypassKey = "Feather.bypassInstallWebView"
    static let defaultWebViewBypass = true
    static let preferredLocalHost = "feather.localhost"
    static let localHosts = [preferredLocalHost, "localhost", "127.0.0.1"]

    static func compatibleLocalHosts(preferred: String, supports: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return ([preferred] + localHosts).filter {
            localHosts.contains($0) && seen.insert($0).inserted && supports($0)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Metadata: Sendable {
        let identifier: String
        let name: String
        let version: String
    }

    static func endpoint(host: String, port: Int, path: String, http: Bool) -> URL {
        var components = URLComponents()
        components.scheme = http ? "http" : "https"
        components.host = host
        components.port = port
        components.path = path
        return components.url!
    }

    static func xmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func hostedManifest(server: String, metadata: Metadata, payload: URL) throws -> URL {
        guard var components = URLComponents(string: server), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil else {
            throw Failure(message: "The hosted plist server must be a valid HTTPS URL.")
        }
        // The default plistworker escapes XML itself. Older custom plistserver
        // endpoints expect XML-escaped values because they interpolate verbatim.
        let workerEscapesXML = host.lowercased() == "api.palera.in" && components.path == "/genPlist"
        func queryText(_ value: String) -> String { workerEscapesXML ? value : xmlText(value) }
        let reserved: Set<String> = ["bundleid", "name", "version", "fetchurl"]
        components.queryItems = (components.queryItems ?? []).filter { !reserved.contains($0.name) } + [
            URLQueryItem(name: "bundleid", value: queryText(metadata.identifier)),
            URLQueryItem(name: "name", value: queryText(metadata.name)),
            URLQueryItem(name: "version", value: queryText(metadata.version)),
            URLQueryItem(name: "fetchurl", value: queryText(payload.absoluteString))
        ]
        // The plistserver API uses form decoding, where an unescaped '+' means space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw Failure(message: "Could not build the hosted manifest URL.") }
        return url
    }

    static func installationURL(manifest: URL) -> URL {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = "" // Preserve the required itms-services://? form.
        // Encode the entire nested URL, including the scheme and nonstandard
        // loopback port. Do not rely on an install client's query parser treating
        // literal ':', '/' and '?' as part of a single URL value.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = manifest.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved)!
        components.percentEncodedQuery = "action=download-manifest&url=" + encoded
        return components.url!
    }

    static func manifest(metadata: Metadata, payload: URL) -> [String: Any] {
        ["items": [[
            // Match the working hosted plist format. Optional icon downloads
            // involve additional installer clients and are unnecessary: the IPA
            // already contains its app icons.
            "assets": [["kind": "software-package", "url": payload.absoluteString]],
            "metadata": ["bundle-identifier": metadata.identifier, "bundle-version": metadata.version,
                         "kind": "software", "title": metadata.name]
        ]]]
    }

    static func validateManifest(_ data: Data, metadata: Metadata, payload: URL) throws {
        guard !data.isEmpty, data.count <= 1_048_576,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let details = items[0]["metadata"] as? [String: Any],
              details["bundle-identifier"] as? String == metadata.identifier,
              details["bundle-version"] as? String == metadata.version,
              let assets = items[0]["assets"] as? [[String: Any]],
              let package = assets.first(where: { $0["kind"] as? String == "software-package" }),
              package["url"] as? String == payload.absoluteString else {
            throw Failure(message: "The plist server returned an invalid manifest or a different app/payload URL.")
        }
    }

    static func handoffHTML(installationURL: URL) -> String {
        // JSON escaping also prevents app metadata from becoming executable HTML.
        let data = try! JSONSerialization.data(withJSONObject: [installationURL.absoluteString], options: [.fragmentsAllowed])
        let destinations = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="font-family:system-ui;padding:32px"><h1>Install App</h1>
        <p>If the installation prompt does not open, tap Install.</p><a id="install">Install</a>
        <script>const target=\(destinations)[0];document.getElementById('install').href=target;window.location.href=target;</script>
        </body></html>
        """
    }
}
