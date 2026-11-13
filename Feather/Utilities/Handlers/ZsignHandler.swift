//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

final class ZsignHandler {
	private(set) var warnings: [String] = []
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		guard let profile = Storage.shared.getFile(.provision, from: cert),
			let key = Storage.shared.getFile(.certificate, from: cert) else {
			throw SigningFileHandlerError.missingCertifcate
		}
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BundleSigning-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let plan = try BundleSigningPlan.make(app: _appUrl, profileURL: profile, options: _options, directory: directory)
		warnings = plan.warnings
		guard Zsign.sign(
			appPath: _appUrl.path, provisionPath: profile.path, p12Path: key.path,
			p12Password: cert.password ?? "", removeProvision: _options.removeProvisioning,
			bundleSettings: plan.settings
		) else { throw SigningFileHandlerError.signFailed }
	}
	
	func adhocSign() async throws {
		// Ad-hoc output is useful for jailbroken/test devices and is not an OTA signature.
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BundleSigning-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let settings = try BundleSigningPlan.makeAdHoc(app: _appUrl, options: _options, directory: directory)
		guard Zsign.sign(appPath: _appUrl.path, adhoc: true, removeProvision: true, bundleSettings: settings) else {
			throw SigningFileHandlerError.signFailed
		}
	}
}
