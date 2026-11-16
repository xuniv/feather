import Foundation
import Vapor

/// Frozen content shared by preflight, Safari and the system installer.
final class InstallationRequestHandler {
    enum Stage {
        case manifest, payload, delivered, failed(Error)
    }

    static let preflightHeader = InstallationTransport.preflightHeader
    let manifestData: Data
    let healthPath: String
    private let sessionID: UUID
    private let manifestPath: String
    private let payloadPath: String
    private let package: URL
    private let html: String
    private let onStage: (Stage) -> Void

    init(sessionID: UUID, metadata: InstallationTransport.Metadata, manifest: URL, payload: URL,
         selectedManifest: URL, package: URL, onStage: @escaping (Stage) -> Void) throws {
        self.sessionID = sessionID
        self.healthPath = "/\(sessionID).health"
        self.manifestPath = manifest.path
        self.payloadPath = payload.path
        self.package = package
        self.onStage = onStage
        self.manifestData = try PropertyListSerialization.data(
            fromPropertyList: InstallationTransport.manifest(metadata: metadata, payload: payload), format: .xml, options: 0)
        try InstallationTransport.validateManifest(manifestData, metadata: metadata, payload: payload)
        self.html = InstallationTransport.handoffHTML(installationURL: InstallationTransport.installationURL(manifest: selectedManifest))
    }

    func respond(to request: Request) -> Response {
        let isDownload = request.method == .GET && request.headers.first(name: Self.preflightHeader) != "1"
        switch request.url.path {
        case healthPath:
            return Response(status: .ok, headers: ["Cache-Control": "no-store"], body: .init(string: sessionID.uuidString))
        case manifestPath:
            if isDownload { onStage(.manifest) }
            return Response(status: .ok, headers: ["Content-Type": "application/xml", "Cache-Control": "no-store"], body: .init(data: manifestData))
        case payloadPath:
            if isDownload { onStage(.payload) }
            return request.fileio.streamFile(at: package.path) { result in
                guard isDownload else { return }
                switch result {
                case .success: self.onStage(.delivered)
                case .failure(let error): self.onStage(.failed(error))
                }
            }
        case "/install":
            return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"], body: .init(string: html))
        default:
            return Response(status: .notFound)
        }
    }
}
