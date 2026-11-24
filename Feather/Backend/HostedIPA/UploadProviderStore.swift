import Combine
import Foundation

@MainActor
final class UploadProviderStore: ObservableObject {
    struct Source: Codable, Identifiable {
        let url: URL
        var catalog: UploadProviderCatalog?
        var lastCheck: Date?
        var refreshFailed = false

        var id: URL { url }

        func needsRefresh(now: Date) -> Bool {
            guard let lastCheck else { return true }
            return now.timeIntervalSince(lastCheck) >= UploadProviderCatalog.refreshInterval || now < lastCheck
        }
    }

    static let shared = UploadProviderStore()
    private static let storageKey = "Feather.uploadProviderSources"
    private static let bundleVersionKey = "Feather.uploadProviderBundleVersion"

    @Published private(set) var sources: [Source]
    @Published private(set) var isRefreshing = false
    private let bundledCatalog: UploadProviderCatalog?

    private init() {
        if let url = Bundle.main.url(forResource: "upload-providers", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            bundledCatalog = try? UploadProviderCatalog.decode(data)
        } else {
            bundledCatalog = nil
        }
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "FeatherForkVersion") as? String ??
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let refreshDefault = bundledCatalog != nil &&
            bundleVersion != UserDefaults.standard.string(forKey: Self.bundleVersionKey)
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Source].self, from: data) {
            sources = saved.filter { UploadProviderCatalog.isHTTPS($0.url) }.map { source in
                if refreshDefault, source.url == UploadProviderCatalog.defaultURL { return Source(url: source.url) }
                guard let catalog = source.catalog else { return source }
                if (try? catalog.validate()) != nil { return source }
                return Source(url: source.url)
            }
        } else {
            sources = [Source(url: UploadProviderCatalog.defaultURL)]
        }
        if refreshDefault {
            persist()
            UserDefaults.standard.set(bundleVersion, forKey: Self.bundleVersionKey)
        }
    }

    private var catalogs: [UploadProviderCatalog] {
        let active = sources.compactMap { source in
            source.catalog ?? (source.url == UploadProviderCatalog.defaultURL ? bundledCatalog : nil)
        }
        if active.isEmpty, let bundledCatalog { return [bundledCatalog] }
        return active
    }

    var providers: [UploadProvider] {
        var seen: Set<String> = []
        return catalogs.flatMap(\.providers).filter { seen.insert($0.id).inserted }
    }

    var preferredProvider: UploadProvider? {
        let available = providers
        return available.first(where: { $0.id == "litterbox" }) ??
            available.first(where: { $0.id == catalogs.first?.defaultProvider }) ??
            available.first
    }

    func saveSource(_ text: String, replacing original: URL?) throws {
        let url = try UploadProviderCatalog.sourceURL(text)
        if url == original { return }
        guard !sources.contains(where: { $0.url == url }) else { throw HostedIPAError.duplicateSource }
        if let original, let index = sources.firstIndex(where: { $0.url == original }) {
            sources[index] = Source(url: url)
        } else {
            sources.append(Source(url: url))
        }
        persist()
    }

    func removeSource(_ url: URL) {
        sources.removeAll { $0.url == url }
        persist()
    }

    func refresh(force: Bool = false) async {
        let now = Date()
        let urls = sources.filter { force || $0.needsRefresh(now: now) }.map(\.url)
        guard !isRefreshing, !urls.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for url in urls {
            let catalog = try? await HostedIPAUpload.fetchCatalog(url)
            if Task.isCancelled { return }
            guard let index = sources.firstIndex(where: { $0.url == url }) else { continue }
            sources[index].lastCheck = Date()
            sources[index].refreshFailed = catalog == nil
            if let catalog { sources[index].catalog = catalog }
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
