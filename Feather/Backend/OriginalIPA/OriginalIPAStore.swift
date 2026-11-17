import Foundation
import Combine

/// Keeps original, licensed packages separate from the resigning library.
@MainActor
final class OriginalIPAStore: ObservableObject {
    struct Item: Identifiable, AppInfoPresentable, Sendable {
        let id: UUID
        let metadata: OriginalIPAMetadata
        let url: URL
        let size: Int64
        let createdAt: Date
        var name: String? { metadata.name }
        var version: String? { metadata.version }
        var identifier: String? { metadata.identifier }
        var date: Date? { createdAt }
        var uuid: String? { nil }
        var icon: String? { nil }
        var source: URL? { nil }
        var isSigned: Bool { true }
    }

    static let shared = OriginalIPAStore()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Original-IPAs", isDirectory: true)
    private let maxBytes: Int64 = 8 * 1024 * 1024 * 1024
    @Published private(set) var items: [Item] = []
    private var active: Set<UUID> = []
    private var timer: Timer?

    private init() {
        try? FileManager.default.removeItem(at: directory)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanup() }
        }
    }

    func add(_ source: URL) async throws {
        cleanup()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard source.pathExtension.lowercased() == "ipa", values.isRegularFile == true,
              values.isSymbolicLink != true, let size = values.fileSize, size > 0, Int64(size) <= maxBytes else {
            throw OriginalIPAMetadata.Failure()
        }
        let id = UUID()
        let target = directory.appendingPathComponent(id.uuidString).appendingPathExtension("ipa")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let metadata = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: target)
                return try OriginalIPAMetadata.read(target)
            }.value
            let actual = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actual == size else { throw OriginalIPAMetadata.Failure() }
            while items.reduce(Int64(size), { $0 + $1.size }) > maxBytes {
                guard let oldest = items.last(where: { !active.contains($0.id) }) else {
                    throw InstallationTransport.Failure(message: "Finish the current installation before importing another IPA.")
                }
                remove(oldest)
            }
            items.insert(.init(id: id, metadata: metadata, url: target, size: Int64(size), createdAt: Date()), at: 0)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func retain(_ item: Item) { active.insert(item.id) }
    func release(_ item: Item) { active.remove(item.id); cleanup() }

    func remove(_ item: Item) {
        guard !active.contains(item.id) else { return }
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
    }

    func cleanup() {
        items.filter { $0.createdAt < Date().addingTimeInterval(-24 * 3600) || !FileManager.default.fileExists(atPath: $0.url.path) }.forEach(remove)
    }
}
