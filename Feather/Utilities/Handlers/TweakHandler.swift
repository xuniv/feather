//
//  DylibHandler.swift
//  feather
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import Zsign
import OSLog

class TweakHandler {
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _directoriesToCheck: [URL] = []
	private var _injectedDylibNames: [String] = []

	private let _app: URL
	private var _options: Options
	private var _urls: [URL]

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles
		if let runtime = options.substrateRuntime {
			self._options.experiment_replaceSubstrateWithEllekit = runtime == .replaceWithElleKit
		}
	}
	
	private func _checkEllekit() async throws {
		if _options.substrateRuntime == .keepExisting { return }
		let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")

		func addEllekit() async throws {
			if let ellekitURL = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
				self._urls.insert(ellekitURL, at: 0)
			} else {
				Logger.misc.info("ellekit.deb not found in the app bundle")
			}
			
			try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
		}
		// we should check if CydiaSubstrate.framework exists, if it doesn't
		// just add ellekit
		// experiment_replaceSubstrateWithEllekit:
		// 	for this version, we need to replace CydiaSubstrate.framework with
		//	our own version containing ElleKit
		// other:
		// 	just return if it exists, should work fine
		if _fileManager.fileExists(atPath: frameworksPath.path) {
			if _options.experiment_replaceSubstrateWithEllekit {
				Logger.misc.info("Attempting to replace Substrate with ElleKit")
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit()
			} else {
				return
			}
		} else {
			guard !_urls.isEmpty else { return }
			try await addEllekit()
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")
		
		if !_options.experiment_replaceSubstrateWithEllekit {
			guard !_urls.isEmpty else { return }
		}

		try await _checkEllekit()

		let baseTmpDir = _fileManager.temporaryDirectory.appendingPathComponent("FeatherTweak_\(UUID().uuidString)")
		try _fileManager.createDirectoryIfNeeded(at: baseTmpDir)
		defer { try? _fileManager.removeItem(at: baseTmpDir) }
		
		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		for url in _urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				try await _handleDeb(at: url, baseTmpDir: baseTmpDir)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
		
		// check contents of data.tar's extracted from debs
		if !_directoriesToCheck.isEmpty {
			try await _handleDirectories(at: _directoriesToCheck)
			if !_urlsToInject.isEmpty {
				try await _handleExtractedDirectoryContents(at: _urlsToInject)
			}
		}

		// inject into all extensions if enabled
		if _options.injectIntoExtensions && !_injectedDylibNames.isEmpty {
			try _injectIntoAllExtensions(dylibNames: _injectedDylibNames)
		}
	}
	
	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws {
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
				let destinationURL = _app.appendingPathComponent("Frameworks").appendingPathComponent(url.lastPathComponent)
				try _copyPayload(from: url, to: destinationURL)
				try await _handleDylib(framework: destinationURL)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _copyPayload(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
	}
	
	private func _copyPayload(from source: URL, to destination: URL) throws {
		guard source.standardizedFileURL != destination.standardizedFileURL else { return }
		try _fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		if _fileManager.fileExists(atPath: destination.path) { try _fileManager.removeItem(at: destination) }
		try _fileManager.copyItem(at: source, to: destination)
	}

	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		var destinationURL = _app
		var injectFolder = _options.injectFolder
		
		// check for "/Frameworks/", then append the destinationUrl
		if _options.injectFolder == .frameworks {
			destinationURL = destinationURL.appendingPathComponent("Frameworks")
		}
		
		// We check for "@rpath" and "/Frameworks/", if they're both enabled force
		// the inject folder to be root "/" instead, as the @rpath is already in
		// frameworks
		if
			_options.injectPath == .rpath && _options.injectFolder == .frameworks
		{
			injectFolder = .root
		}
		
		destinationURL = destinationURL.appendingPathComponent(url.lastPathComponent)
		
		
		try _copyPayload(from: url, to: destinationURL)
		
		guard let appexe = Bundle(url: _app)?.executableURL else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: destinationURL.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		let loadPath = "\(_options.injectPath.rawValue)\(injectFolder.rawValue)\(destinationURL.lastPathComponent)"
		guard Zsign.listDylibs(appExecutable: appexe.path).contains(loadPath) ||
			Zsign.injectDyLib(appExecutable: appexe.path, with: loadPath) else {
			throw EntitlementPolicy.Failure(message: "Failed to inject \(destinationURL.lastPathComponent).")
		}

		_injectedDylibNames.append(destinationURL.lastPathComponent)
	}
	
	// Inject imported framework dir
	private func _handleDylib(framework: URL) async throws {
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
			return
		}
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: fexe.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
		let loadPath = "@executable_path/Frameworks/\(framework.lastPathComponent)/\(fexe.lastPathComponent)"
		guard Zsign.listDylibs(appExecutable: appexe.path).contains(loadPath) ||
			Zsign.injectDyLib(appExecutable: appexe.path, with: loadPath) else {
			throw EntitlementPolicy.Failure(message: "Failed to inject \(framework.lastPathComponent).")
		}
		_injectedDylibNames.append("\(framework.lastPathComponent)/\(fexe.lastPathComponent)")
	}
	
	// Extracy imported deb file
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)
		
		// I don't particularly like this code
		// but it somehow works well enough,
		// do note large lzma's are slow as hell
		
		let handler = AR(with: url)
		let arFiles = try await handler.extract()
		
		for arFile in arFiles {
			let outputPath = uniqueSubDir.appendingPathComponent(arFile.name)
			try arFile.content.write(to: outputPath)
			
			if ["data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2"].contains(arFile.name) {
				var fileToProcess = outputPath
				try extractFile(at: &fileToProcess)
				try extractFile(at: &fileToProcess)
				_directoriesToCheck.append(fileToProcess)
			}
		}
	}
	
	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}
		
		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: ["Library/MobileSubstrate/DynamicLibraries/", "var/jb/Library/MobileSubstrate/DynamicLibraries/"],
			.applicationSupport: ["Library/Application Support/", "var/jb/Library/Application Support/"]
		]
				
		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)
					
					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						Logger.misc.warning("Directory does not exist: \(directoryURL.path). Skipping.")
						continue
					}
					
					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(in: directoryURL)
						_urlsToInject.append(contentsOf: dylibFiles)
						
					case .frameworks:
						let frameworkDirectories = try await _locateFrameworkDirectories(in: directoryURL)
						_urlsToInject.append(contentsOf: frameworkDirectories)
						
					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}

	// Extensions may be nested inside companion apps as well as PlugIns.
	private func _discoverAppExtensions() -> [URL] {
		guard let enumerator = _fileManager.enumerator(at: _app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
		var extensions: [URL] = []
		for case let url as URL in enumerator {
			if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
			if url.pathExtension == "appex" { extensions.append(url) }
		}
		return extensions
	}

	// Injects a dylib into an extension's executable
	private func _injectIntoExtension(extensionURL: URL, dylibName: String) throws {
		guard 
			let extensionBundle = Bundle(url: extensionURL),
			let extensionExecutable = extensionBundle.executableURL 
		else {
			Logger.misc.warning("Skipping \(extensionURL.lastPathComponent): couldn't read bundle")
			return
		}
		
		// Extension processes do not inherit the main app's @rpath search list.
		let depth = extensionURL.pathComponents.count - _app.pathComponents.count
		let inFrameworks = dylibName.contains(".framework/") || _options.injectFolder == .frameworks
		let injectPath = "@executable_path/" + String(repeating: "../", count: depth) + (inFrameworks ? "Frameworks/" : "") + dylibName
		if Zsign.listDylibs(appExecutable: extensionExecutable.path).contains(injectPath) { return }

		let success = Zsign.injectDyLib(
			appExecutable: extensionExecutable.path,
			with: injectPath
		)
		
		if success {
			Logger.misc.info("Injected \(dylibName) into extension: \(extensionURL.lastPathComponent)")
		} else {
			throw EntitlementPolicy.Failure(message: "Failed to inject into extension: \(extensionURL.lastPathComponent)")
		}
	}

	// Injects all dylibs into all discovered extensions
	private func _injectIntoAllExtensions(dylibNames: [String]) throws {
		let extensions = _discoverAppExtensions()

		guard !extensions.isEmpty else {
			Logger.misc.info("No app extensions found for injection")
			return
		}

		Logger.misc.info("Found \(extensions.count) app extension(s) for injection")

		for extensionURL in extensions {
			for dylibName in dylibNames {
				try _injectIntoExtension(extensionURL: extensionURL, dylibName: dylibName)
			}
		}
	}
}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}
		
		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}
		
		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}
		
		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
		
		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
		
		return frameworkDirectories
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
