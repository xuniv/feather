//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
    private func endpoint(_ path: String) -> URL {
        InstallationTransport.endpoint(host: host, port: port, path: path, http: method.usesHTTP)
    }

    var plistEndpoint: URL { endpoint("/\(id).plist") }
    var payloadEndpoint: URL { endpoint("/\(id).ipa") }
    var pageEndpoint: URL { endpoint("/install") }
    var displayImageSmallEndpoint: URL { endpoint("/app57x57.png") }
    var displayImageLargeEndpoint: URL { endpoint("/app512x512.png") }

    static func createIcon(_ size: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: .init(width: size, height: size))
        return renderer.image { context in
            UIColor.tintColor.setFill()
            context.fill(.init(x: 0, y: 0, width: size, height: size))
        }.pngData() ?? Data()
    }

    var installManifestData: Data {
        // All values are concrete strings, not Optional values from Core Data.
        let manifest = InstallationTransport.manifest(metadata: metadata, payload: payloadEndpoint,
            smallIcon: displayImageSmallEndpoint, largeIcon: displayImageLargeEndpoint)
        return (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
    }
}
