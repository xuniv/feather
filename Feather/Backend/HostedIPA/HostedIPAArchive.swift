import Foundation
import ZIPFoundation

/// Owns the exact archive shown in the upload sheet until the sheet and its requests finish.
final class HostedIPAArchive: Sendable {
    let file: URL
    let size: Int64
    let metadata: InstallationTransport.Metadata?
    private let directory: URL

    private init(file: URL, size: Int64, metadata: InstallationTransport.Metadata?, directory: URL) {
        self.file = file
        self.size = size
        self.metadata = metadata
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func prepare(app: URL, forInstallation: Bool) async throws -> HostedIPAArchive {
        let progress = Progress(totalUnitCount: 0)
        let work = Task.detached(priority: .userInitiated) {
            try build(app: app, forInstallation: forInstallation, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            progress.cancel()
            work.cancel()
        }
    }

    private static func build(app: URL, forInstallation: Bool, progress: Progress) throws -> HostedIPAArchive {
        let manager = FileManager.default
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HostedIPAError.missingBundle
        }

        let directory = manager.temporaryDirectory.appendingPathComponent("FeatherUpload-\(UUID())", isDirectory: true)
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let packagedApp = payload.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        let ipa = directory.appendingPathComponent("App.ipa")
        do {
            try manager.createDirectory(at: payload, withIntermediateDirectories: true)
            try manager.copyItem(at: app, to: packagedApp)
            try checkSymlinks(in: packagedApp)
            try Task.checkCancellation()

            // ZIPFoundation preserves Unix permissions and symlinks and supports ZIP64.
            try manager.zipItem(at: payload, to: ipa, shouldKeepParent: true, compressionMethod: .deflate, progress: progress)
            try manager.removeItem(at: payload)
            try Task.checkCancellation()

            guard let bytes = try ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else {
                throw HostedIPAError.emptyFile
            }
            let metadata: InstallationTransport.Metadata?
            if forInstallation {
                let info = try OriginalIPAMetadata.read(ipa)
                metadata = .init(identifier: info.identifier, name: info.name, version: info.build)
            } else {
                metadata = nil
            }
            return HostedIPAArchive(file: ipa, size: Int64(bytes), metadata: metadata, directory: directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func checkSymlinks(in app: URL) throws {
        let manager = FileManager.default
        let appPath = app.resolvingSymlinksInPath().path + "/"
        var traversalError: Error?
        guard let entries = manager.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in
                traversalError = error
                return false
            }) else { throw HostedIPAError.missingBundle }

        for case let entry as URL in entries {
            try Task.checkCancellation()
            guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            let target = try manager.destinationOfSymbolicLink(atPath: entry.path)
            let resolved = entry.deletingLastPathComponent().appendingPathComponent(target).resolvingSymlinksInPath()
            guard !target.hasPrefix("/"), resolved.path.hasPrefix(appPath) else { throw HostedIPAError.unsafeSymlink }
        }
        if let traversalError { throw traversalError }
    }
}
