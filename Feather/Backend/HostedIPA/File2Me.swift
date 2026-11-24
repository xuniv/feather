import Foundation

enum File2Me {
    static let origin = URL(string: "https://file2.me")!
    static let presign = origin.appendingPathComponent("api/upload/presign")
    static let confirm = origin.appendingPathComponent("api/upload/confirm")
    static let share = origin.appendingPathComponent("api/share")
    static let maximumFileSize: Int64 = 500_000_000
    static let expiries: Set<String> = ["1h", "12h", "24h", "7d"]

    struct Reservation: Decodable {
        let presignedUrl: URL
        let storageKey: String
        let uploadGrant: String
    }

    struct Confirmation: Decodable {
        struct File: Decodable { let id: String }
        let file: File
    }

    struct Share: Decodable {
        struct Link: Decodable { let id: String }
        let share: Link
    }

    static func rawURL(shareID: String) throws -> URL {
        guard isShareID(shareID) else { throw HostedIPAError.invalidLink }
        return origin.appendingPathComponent("raw").appendingPathComponent(shareID)
    }

    static func allowsRawURL(_ url: URL) -> Bool {
        let parts = url.pathComponents
        return UploadProviderCatalog.isHTTPS(url) && url.host == origin.host && url.port == nil && url.query == nil
            && parts.count == 3 && parts[1] == "raw" && isShareID(parts[2])
            && url.path == "/raw/\(parts[2])"
    }

    static func allowsStorageURL(_ url: URL) -> Bool {
        // file2.me's guest service signs requests to its Cloudflare R2 bucket.
        guard UploadProviderCatalog.isHTTPS(url), url.port == nil,
              let host = url.host, host.range(of: #"\A[a-f0-9]{32}\.r2\.cloudflarestorage\.com\z"#,
                                             options: .regularExpression) != nil,
              url.pathComponents.count > 2,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return query.contains { $0.name == "X-Amz-Signature" && ($0.value?.isEmpty == false) }
    }

    static func storageRedirect(from raw: URL, status: Int, location: String?) throws -> URL {
        guard allowsRawURL(raw), status == 307,
              let location, let target = URL(string: location), allowsStorageURL(target) else {
            throw HostedIPAError.invalidLink
        }
        return target
    }

    private static func isShareID(_ id: String) -> Bool {
        id.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil
    }
}
