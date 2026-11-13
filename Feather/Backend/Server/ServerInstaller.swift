//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import SwiftUI
import IDeviceSwift

class ServerInstaller: Identifiable, ObservableObject {
    let id = UUID()
    let port = Int.random(in: 4000...8000)
    let method: InstallationServerMethod
    let metadata: InstallationTransport.Metadata
    let hostedServer: String
    let ipFix: Bool
    private(set) var host = "127.0.0.1"
    private(set) var selectedManifest: URL?
    private var packageUrl: URL?
    private let server = InstallationHTTPServer()
    private let smallIcon: Data
    private let largeIcon: Data
    @ObservedObject var viewModel: InstallerStatusViewModel

    // Export and pairing installation must not require an HTTPS identity.
    // Starting the server is deferred to start(package:) so failures reach the UI.
    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
        self.viewModel = viewModel
        let defaults = UserDefaults.standard
        method = InstallationServerMethod(rawValue: defaults.integer(forKey: "Feather.serverMethod")) ?? .localCA
        hostedServer = defaults.string(forKey: "Feather.hostedPlistServer") ?? InstallationTransport.defaultHostedServer
        ipFix = defaults.bool(forKey: "Feather.ipFix")
        let info = Storage.shared.getAppDirectory(for: app).flatMap { Bundle(url: $0)?.infoDictionary }
        metadata = .init(identifier: info?["CFBundleIdentifier"] as? String ?? app.identifier ?? "",
                         name: app.name ?? "App",
                         version: info?["CFBundleVersion"] as? String ?? app.version ?? "1")
        smallIcon = Self.createIcon(57)
        largeIcon = Self.createIcon(512)
    }

    func start(package: URL) async throws {
        guard !metadata.identifier.isEmpty else {
            throw InstallationTransport.Failure(message: "The app is missing its bundle identifier.")
        }
        packageUrl = package
        let preferred = UserDefaults.standard.string(forKey: "Feather.localInstallHost") ?? InstallationTransport.preferredLocalHost
        let candidates: [String]
        if method.usesLocalCA {
            candidates = try LocalTLSAuthority.shared.hostCandidates(preferred: preferred)
        } else if method.usesHTTP {
            candidates = ipFix ? ["127.0.0.1"] : [Self.getLocalAddress(), "127.0.0.1"].compactMap { $0 }
        } else {
            candidates = [readCommonName() ?? "localhost.backloop.dev"]
        }
        host = candidates[0]
        do {
            try server.start(port: port, tls: method.usesHTTP ? nil : tls(), localOnly: !method.usesHTTP) { [weak self] request in
                guard let self else { return Response(status: .serviceUnavailable) }
                return self.respond(to: request)
            }
            // System TLS and real name resolution are checked before announcing Ready.
            // Older trusted certificates automatically use their existing localhost SAN.
            try await checkLocalConnection(candidates: candidates)
            selectedManifest = try method.usesHostedManifest
                ? InstallationTransport.hostedManifest(server: hostedServer, metadata: metadata, payload: payloadEndpoint)
                : plistEndpoint
            if method.usesHostedManifest { try await checkHostedManifest() }
        } catch {
            server.shutdown()
            throw error
        }
    }

    private func checkLocalConnection(candidates: [String]) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var lastError: Error?
        for candidate in candidates {
            do {
                let url = InstallationTransport.endpoint(host: candidate, port: port, path: "/\(id).health", http: method.usesHTTP)
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      data == Data(id.uuidString.utf8) else {
                    throw InstallationTransport.Failure(message: "Unexpected response from the local installation server.")
                }
                host = candidate
                return
            } catch { lastError = error }
        }
        throw InstallationTransport.Failure(message: "Cannot connect to the local installation server (\(candidates.joined(separator: ", "))): \(lastError?.localizedDescription ?? "Unknown error"). Check Local CA Trust in Installation settings, or try Hosted Plist (HTTP).")
    }

    private func checkHostedManifest() async throws {
        guard let url = selectedManifest else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw InstallationTransport.Failure(message: "The hosted plist server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
            }
            try InstallationTransport.validateManifest(data, metadata: metadata, payload: payloadEndpoint)
        } catch {
            throw InstallationTransport.Failure(message: "Hosted plist check failed: \(error.localizedDescription) Try another HTTPS plist server in Installation settings, or use Local CA (Offline).")
        }
    }

    private func respond(to request: Request) -> Response {
        switch request.url.path {
        case "/\(id).health":
            return Response(status: .ok, headers: ["Cache-Control": "no-store"], body: .init(string: id.uuidString))
        case plistEndpoint.path:
            updateStatus(.sendingManifest)
            return Response(status: .ok, headers: ["Content-Type": "application/xml", "Cache-Control": "no-store"], body: .init(data: installManifestData))
        case displayImageSmallEndpoint.path:
            return Response(status: .ok, headers: ["Content-Type": "image/png"], body: .init(data: smallIcon))
        case displayImageLargeEndpoint.path:
            return Response(status: .ok, headers: ["Content-Type": "image/png"], body: .init(data: largeIcon))
        case payloadEndpoint.path:
            guard let packageUrl else { return Response(status: .notFound) }
            updateStatus(.sendingPayload)
            return request.fileio.streamFile(at: packageUrl.path) { result in
                switch result {
                case .success: self.updateStatus(.installing)
                case .failure(let error): self.updateStatus(.broken(error))
                }
            }
        case "/install":
            guard let selectedManifest else { return Response(status: .serviceUnavailable) }
            let html = InstallationTransport.handoffHTML(installationURL: InstallationTransport.installationURL(manifest: selectedManifest))
            return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"], body: .init(string: html))
        default:
            return Response(status: .notFound)
        }
    }

    private func updateStatus(_ status: InstallerStatusViewModel.InstallerStatus) {
        DispatchQueue.main.async { self.viewModel.status = status }
    }
}
