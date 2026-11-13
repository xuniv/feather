import Foundation
import Vapor
import NIOSSL

/// HTTPS listeners stay on loopback, including IPv6 for .localhost resolution.
final class InstallationHTTPServer {
    private var applications: [Application] = []

    func start(port: Int, tls: TLSConfiguration?, localOnly: Bool,
               handler: @escaping (Request) throws -> Response) throws {
        precondition(applications.isEmpty)
        do {
            for address in localOnly ? ["127.0.0.1", "::1"] : ["0.0.0.0"] {
                let application = Application(.production)
                applications.append(application)
                application.threadPool = .init(numberOfThreads: 1)
                application.http.server.configuration.address = .hostname(address, port: port)
                application.http.server.configuration.tcpNoDelay = true
                application.http.server.configuration.tlsConfiguration = tls
                application.routes.caseInsensitive = false
                application.get("*") { request in try handler(request) }
                try application.server.start()
            }
        } catch {
            shutdown()
            throw error
        }
    }

    func shutdown() {
        for application in applications.reversed() {
            // These listeners are started directly, outside Application.run().
            // Application.shutdown() alone does not stop their HTTPServer.
            application.server.shutdown()
            application.shutdown()
        }
        applications.removeAll()
    }

    deinit { shutdown() }
}
