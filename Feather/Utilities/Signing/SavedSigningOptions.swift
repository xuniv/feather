import Foundation

/// Stored beside the signed bundle so exports contain only the app.
struct SavedSigningOptions: Codable {
	var options: Options
	let iconPNG: Data?

	private static let filename = "SigningOptions.json"
	private static let inputDirectory = "SigningInputs"

	static func write(_ options: Options, iconPNG: Data?, to directory: URL) throws {
		let files = FileManager.default
		let documents = URL.documentsDirectory.resolvingSymlinksInPath().path + "/"
		let signed = files.signed.resolvingSymlinksInPath().path + "/"
		let inputs = directory.appendingPathComponent(inputDirectory, isDirectory: true)
		var saved = options
		var references: [URL: URL] = [:]

		do {
			try saved.mapInputFiles { url in
				if let reference = references[url] { return reference }
				let path = url.resolvingSymlinksInPath().path
				var reference = URLComponents()
				if path.hasPrefix(documents), !path.hasPrefix(signed) {
					reference.path = "Documents/" + String(path.dropFirst(documents.count))
				} else {
					// File-picker copies can be purged from tmp. Keep a local copy, also
					// when the file was restored from an older signed entry's settings.
					let folder = UUID().uuidString
					let destination = inputs.appendingPathComponent(folder, isDirectory: true)
					try files.createDirectory(at: destination, withIntermediateDirectories: true)
					try files.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
					reference.path = "\(inputDirectory)/\(folder)/\(url.lastPathComponent)"
				}
				guard let encoded = reference.url else { throw CocoaError(.fileWriteInvalidFileName) }
				references[url] = encoded
				return encoded
			}
			let data = try JSONEncoder().encode(Self(options: saved, iconPNG: iconPNG))
			try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
		} catch {
			try? files.removeItem(at: inputs)
			throw error
		}
	}

	static func load(from directory: URL) throws -> Self {
		let data = try Data(contentsOf: directory.appendingPathComponent(filename))
		var saved = try JSONDecoder().decode(Self.self, from: data)
		try saved.options.mapInputFiles { reference in
			let path = reference.path.split(separator: "/", omittingEmptySubsequences: false)
			guard reference.scheme == nil, path.count > 1, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
				throw CocoaError(.fileReadCorruptFile)
			}
			switch path[0] {
			case "Documents":
				return URL.documentsDirectory.appendingPathComponent(path.dropFirst().joined(separator: "/"))
			case inputDirectory:
				return directory.appendingPathComponent(reference.path)
			default:
				throw CocoaError(.fileReadCorruptFile)
			}
		}
		return saved
	}
}

extension Options {
	fileprivate mutating func mapInputFiles(_ transform: (URL) throws -> URL) rethrows {
		appEntitlementsFile = try appEntitlementsFile.map(transform)
		additionalProvisioningProfiles = try additionalProvisioningProfiles?.map(transform)
		ipaPatchRuntime = try ipaPatchRuntime.map(transform)
		injectionFiles = try injectionFiles.map(transform)
	}

	var missingSigningInputs: [URL] {
		var inputs = injectionFiles + (additionalProvisioningProfiles ?? [])
		if let appEntitlementsFile { inputs.append(appEntitlementsFile) }
		if let ipaPatchMode, ipaPatchMode != .off, let ipaPatchRuntime { inputs.append(ipaPatchRuntime) }
		return inputs.filter { !FileManager.default.fileExists(atPath: $0.path) }
	}
}
