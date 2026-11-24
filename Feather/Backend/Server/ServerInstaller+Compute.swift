//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation

extension ServerInstaller {
    private func endpoint(_ path: String) -> URL {
        InstallationTransport.endpoint(host: host, port: port, path: path, http: method.usesHTTP)
    }

    var plistEndpoint: URL { endpoint("/\(id).plist") }
    var payloadEndpoint: URL { endpoint("/\(id).ipa") }
    var pageEndpoint: URL { endpoint("/install") }
    var installationURL: URL? {
        selectedManifest.map { InstallationTransport.installationURL(manifest: $0) }
    }
}
