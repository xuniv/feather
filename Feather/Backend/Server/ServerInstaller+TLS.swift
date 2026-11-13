//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	func setupApp(port: Int) throws -> Application {
		let app = Application(Self.env)
		app.threadPool = .init(numberOfThreads: 1)
		
		if getServerMethod() != 1 {
			do {
				guard let configuration = try tls() else {
					throw EntitlementPolicy.Failure(message: "Missing HTTPS certificate or private key. Update SSL Certificates in Installation settings.")
				}
				app.http.server.configuration.tlsConfiguration = configuration
			} catch {
				app.shutdown()
				throw error
			}
		}
		
		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname(getServerMethod() == 0 ? "127.0.0.1" : "0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		
		return app
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 0 { return localhost }
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		} else {
			return readCommonName() ?? localhost
		}
	}
	
	func tls() throws -> TLSConfiguration? {
		let crt: URL
		let pem: URL
		if getServerMethod() == 0 {
			try LocalTLSAuthority.shared.requireTrust()
			crt = LocalTLSAuthority.shared.certificateURL
			pem = LocalTLSAuthority.shared.keyURL
		} else {
			guard let certificate = Self.getUrl("server", ext: "crt"), let key = Self.getUrl("server", ext: "pem") else { return nil }
			crt = certificate
			pem = key
		}
		
		return try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(crt.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: pem.path, format: .pem)
			)
		)
	}
	
	func readCommonName() -> String? {
		guard let url = Self.getUrl("commonName", ext: "txt") else {
			return nil
		}
		
		guard let name = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
		return name.hasPrefix("*.") ? "localhost." + name.dropFirst(2) : name
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default
		
		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		let bundlesURL = Bundle.main.url(forResource: name, withExtension: ext)
		
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}
		
		if let bundlesURL, fileManager.fileExists(atPath: bundlesURL.path) {
			return bundlesURL
		}
		
		return nil
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
						               &hostname, socklen_t(hostname.count),
						               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
