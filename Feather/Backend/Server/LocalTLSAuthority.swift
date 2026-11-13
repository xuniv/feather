import Foundation
import Security
import ZsignC
import Vapor
import UIKit

/// A device-specific loopback identity. No private signing material is served.
final class LocalTLSAuthority {
    static let shared = LocalTLSAuthority()
    private let identityLock = NSRecursiveLock()
    private var setupServer: Application?
    private var setupTimeout: Timer?

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalInstallationTLS", isDirectory: true)
    }

    var certificateURL: URL { directory.appendingPathComponent("server.crt") }
    var keyURL: URL { directory.appendingPathComponent("server.pem") }
    private var authorityURL: URL { directory.appendingPathComponent("authority.der") }

    func prepare() throws {
        identityLock.lock()
        defer { identityLock.unlock() }
        let manager = FileManager.default
        let files = [certificateURL, keyURL, authorityURL]
        if files.allSatisfy({ manager.fileExists(atPath: $0.path) }) { return }
        guard let identity = CreateLocalTLSIdentity(),
              let certificate = identity["certificate"], let key = identity["key"], let authority = identity["authority"] else {
            throw EntitlementPolicy.Failure(message: "Could not generate the local installation certificate.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
        for (file, data) in [(certificateURL, certificate), (keyURL, key), (authorityURL, authority)] {
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func requireTrust() throws {
        identityLock.lock()
        defer { identityLock.unlock() }
        try prepare()
        // Evaluate using the system trust store; never install a custom trust anchor here.
        let pem = try String(contentsOf: certificateURL, encoding: .utf8)
        let certificates = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block -> SecCertificate? in
            guard let end = block.range(of: "-----END CERTIFICATE-----"),
                  let data = Data(base64Encoded: String(block[..<end.lowerBound]), options: .ignoreUnknownCharacters) else { return nil }
            return SecCertificateCreateWithData(nil, data as CFData)
        }
        var trust: SecTrust?
        guard !certificates.isEmpty,
              SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &trust) == errSecSuccess,
              let trust, SecTrustEvaluateWithError(trust, nil) else {
            throw EntitlementPolicy.Failure(message: "Local HTTPS is not trusted or its certificate has expired. In Settings → Installation, set up the Local CA. Install the profile, then enable it in iOS Settings → General → About → Certificate Trust Settings. If already enabled, use Reset Local CA and repeat setup.")
        }
    }

    @MainActor
    func openSetup() throws {
        try prepare()
        setupTimeout?.invalidate()
        setupServer?.shutdown()
        setupServer = nil
        let authority = try Data(contentsOf: authorityURL)
        let payloadID = "app.feather.local-installation-ca"
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": payloadID, "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Feather Local Installation CA",
            "PayloadDescription": "Allows HTTPS installation from Feather on this device. Enable full trust after installing.",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": payloadID + ".root", "PayloadUUID": UUID().uuidString,
                "PayloadDisplayName": "Feather Local Installation CA", "PayloadContent": authority
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let server = Application(.production)
        server.http.server.configuration.hostname = "127.0.0.1"
        let port = Int.random(in: 40000...50000)
        server.http.server.configuration.port = port
        // An unguessable, short-lived route carries only the public root certificate.
        let token = UUID().uuidString
        server.get(PathComponent(stringLiteral: token), "ca.mobileconfig") { _ in
            Response(status: .ok, headers: ["Content-Type": "application/x-apple-aspen-config"], body: .init(data: data))
        }
        do { try server.server.start() } catch { server.shutdown(); throw error }
        setupServer = server
        setupTimeout = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            self?.setupServer?.shutdown()
            self?.setupServer = nil
        }
        UIApplication.shared.open(URL(string: "http://127.0.0.1:\(port)/\(token)/ca.mobileconfig")!)
    }

    func reset() throws {
        identityLock.lock()
        defer { identityLock.unlock() }
        // Called only from the explicit Reset Local CA action.
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try prepare()
    }
}
