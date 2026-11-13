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
	func tls() throws -> TLSConfiguration {
		let crt: URL
		let pem: URL
		if method.usesLocalCA {
			try LocalTLSAuthority.shared.requireTrust(host: host)
			crt = LocalTLSAuthority.shared.certificateURL
			pem = LocalTLSAuthority.shared.keyURL
		} else {
			guard let certificate = Self.getUrl("server", ext: "crt"), let key = Self.getUrl("server", ext: "pem") else {
				throw InstallationTransport.Failure(message: "Missing HTTPS certificate or private key. Update SSL Certificates in Installation settings.")
			}
			crt = certificate
			pem = key
		}
		return try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(crt.path).map { .certificate($0) },
			privateKey: .privateKey(NIOSSLPrivateKey(file: pem.path, format: .pem))
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
				guard let socketAddress = interface.ifa_addr else {
						ptr = interface.ifa_next
						continue
					}
					let addrFamily = socketAddress.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
									   &hostname, socklen_t(hostname.count),
									   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
							if name == "en0" { freeifaddrs(ifaddr); return address }
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
