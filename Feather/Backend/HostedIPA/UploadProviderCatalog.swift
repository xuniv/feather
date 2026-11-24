import Foundation

struct UploadProviderCatalog: Codable, Sendable {
    static let defaultURL = URL(string: "https://raw.githubusercontent.com/xuniv/feather/main/upload-providers.json")!
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumBytes = 128 * 1024

    let schemaVersion: Int
    let defaultProvider: String?
    private let multipartProviders: [UploadProvider]
    private let file2Me: UploadProvider?

    // Older clients read only the multipart list from the same catalog URL.
    var providers: [UploadProvider] { multipartProviders + [file2Me].compactMap { $0 } }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, defaultProvider, file2Me
        case multipartProviders = "providers"
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw HostedIPAError.invalidCatalog }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        let providers = self.providers
        let identifiers = Set(providers.map(\.id))
        guard schemaVersion == 1, providers.count <= 50, identifiers.count == providers.count,
              multipartProviders.allSatisfy({ !$0.usesFile2Me }), file2Me?.usesFile2Me ?? true,
              defaultProvider.map(identifiers.contains) ?? true else { throw HostedIPAError.invalidCatalog }
        for provider in providers { try provider.validate() }
    }

    static func sourceURL(_ text: String) throws -> URL {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), isHTTPS(url) else { throw HostedIPAError.invalidSourceURL }
        return url
    }

    static func isHTTPS(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host?.isEmpty ?? true) &&
            parts.user == nil && parts.password == nil && parts.fragment == nil
    }
}

struct UploadProvider: Codable, Equatable, Identifiable, Sendable {
    struct Upload: Codable, Equatable, Sendable {
        enum Method: String, Codable, Sendable { case file2Me = "file2me" }

        let url: URL
        let method: Method?
        let fileField: String?
        let fields: [String: String]
        let ipaFilename: String
        let manifestFilename: String
        let response: Response?
        let ua: UserAgent?
    }

    struct Response: Codable, Equatable, Sendable {
        enum Format: String, Codable, Sendable { case plainTextURL, jsonURL }
        let format: Format
        let path: [String]?
    }

    enum UserAgent: Codable, Equatable, Sendable {
        case literal(String)
        case feather
        case curl

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .literal(value)
            } else {
                self = try container.decode(Bool.self) ? .feather : .curl
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .literal(let value): try container.encode(value)
            case .feather: try container.encode(true)
            case .curl: try container.encode(false)
            }
        }

        var isValid: Bool {
            guard case .literal(let value) = self else { return true }
            return !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (32...126).contains($0) }
        }
    }

    struct Download: Codable, Equatable, Sendable {
        let hosts: [String]
        let manifestMIMETypes: [String]
        let allowQuery: Bool?
    }

    struct Option: Codable, Equatable, Identifiable, Sendable {
        struct Choice: Codable, Equatable, Identifiable, Sendable {
            let id: String
            let label: String
            let fields: [String: String]
        }
        let id: String
        let label: String
        let defaultChoice: String
        let choices: [Choice]
    }

    let id: String
    let name: String
    let fileLimitBytes: Int64
    let requestLimitBytes: Int64?
    let upload: Upload
    let download: Download
    let options: [Option]
    let retentionNote: String?

    var usesFile2Me: Bool { upload.method == .file2Me }

    func accepts(size: Int64) -> Bool { size > 0 && size <= fileLimitBytes }

    func userAgent(bundleID: String, version: String) -> String {
        switch upload.ua ?? .curl {
        case .literal(let value): return value
        case .feather: return "Feather/\(version) (\(bundleID))"
        case .curl: return "curl"
        }
    }

    func fields(choices: [String: String]) throws -> [String: String] {
        var fields = upload.fields
        for option in options {
            let id = choices[option.id] ?? option.defaultChoice
            guard let choice = option.choices.first(where: { $0.id == id }) else {
                throw HostedIPAError.invalidOptions
            }
            fields.merge(choice.fields) { _, value in value }
        }
        return fields
    }

    func allowsDownload(_ url: URL) -> Bool {
        if usesFile2Me { return File2Me.allowsRawURL(url) }
        return UploadProviderCatalog.isHTTPS(url) &&
            download.hosts.contains { $0.caseInsensitiveCompare(url.host ?? "") == .orderedSame } &&
            (url.query == nil || download.allowQuery == true) &&
            !url.path.isEmpty && url.path != "/"
    }

    func downloadURL(from data: Data) throws -> URL {
        guard data.count <= 8_192, let response = upload.response else { throw HostedIPAError.invalidLink }
        let value: String?
        switch response.format {
        case .plainTextURL:
            value = String(data: data, encoding: .utf8)
        case .jsonURL:
            var object: Any? = try? JSONSerialization.jsonObject(with: data)
            for key in response.path ?? [] {
                object = (object as? [String: Any])?[key]
            }
            value = object as? String
        }
        guard let link = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              link.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URL(string: link), allowsDownload(url) else { throw HostedIPAError.invalidLink }
        return url
    }

    func validate() throws {
        guard Self.token(id), Self.label(name), fileLimitBytes > 0,
              requestLimitBytes.map({ $0 >= fileLimitBytes }) ?? true,
              upload.ua?.isValid ?? true,
              UploadProviderCatalog.isHTTPS(upload.url),
              Self.token(upload.ipaFilename), upload.ipaFilename.lowercased().hasSuffix(".ipa"),
              Self.token(upload.manifestFilename),
              [".xml", ".plist"].contains(where: upload.manifestFilename.lowercased().hasSuffix),
              !download.hosts.isEmpty, download.hosts.count <= 8,
              download.hosts.allSatisfy(Self.token),
              !download.manifestMIMETypes.isEmpty, download.manifestMIMETypes.count <= 4,
              download.manifestMIMETypes.allSatisfy({ ["text/xml", "application/xml", "application/x-plist"].contains($0) }),
              retentionNote.map(Self.label) ?? true,
              options.count <= 8, Set(options.map(\.id)).count == options.count else { throw HostedIPAError.invalidCatalog }

        if usesFile2Me {
            guard id == "file2-me", upload.url == File2Me.presign, download.hosts == ["file2.me"],
                  upload.fileField == nil, upload.response == nil, download.allowQuery != true,
                  fileLimitBytes <= File2Me.maximumFileSize, requestLimitBytes == nil else {
                throw HostedIPAError.invalidCatalog
            }
        } else {
            guard let field = upload.fileField, Self.token(field), let response = upload.response else {
                throw HostedIPAError.invalidCatalog
            }
            let path = response.path ?? []
            switch response.format {
            case .plainTextURL:
                guard path.isEmpty else { throw HostedIPAError.invalidCatalog }
            case .jsonURL:
                guard (1...8).contains(path.count), path.allSatisfy(Self.token) else { throw HostedIPAError.invalidCatalog }
            }
        }

        try validateFields(upload.fields)
        for option in options {
            let identifiers = Set(option.choices.map(\.id))
            guard Self.token(option.id), Self.label(option.label), (1...32).contains(option.choices.count),
                  identifiers.count == option.choices.count, identifiers.contains(option.defaultChoice) else {
                throw HostedIPAError.invalidCatalog
            }
            for choice in option.choices {
                guard Self.token(choice.id), Self.label(choice.label) else { throw HostedIPAError.invalidCatalog }
                try validateFields(choice.fields)
            }
        }
    }

    private func validateFields(_ fields: [String: String]) throws {
        if usesFile2Me, !fields.isEmpty {
            guard fields.count == 1, let expiry = fields["expiry"], File2Me.expiries.contains(expiry) else {
                throw HostedIPAError.invalidCatalog
            }
        }
        guard fields.count <= 16, !(upload.fileField.map { fields[$0] != nil } ?? false),
              fields.keys.allSatisfy(Self.token),
              fields.values.allSatisfy({ $0.utf8.count <= 1_024 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw HostedIPAError.invalidCatalog
        }
    }

    private static func token(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$"#, options: .regularExpression) != nil
    }

    private static func label(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 200 &&
            text.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

enum HostedIPAError: LocalizedError {
    case invalidCatalog, invalidSourceURL, duplicateSource, invalidOptions
    case missingBundle, emptyFile, tooLarge, unsafeSymlink, invalidLink, invalidDownload, invalidManifest
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: NSLocalizedString("The provider list could not be loaded or has an invalid format.", comment: "")
        case .invalidSourceURL: NSLocalizedString("Enter a valid HTTPS provider list URL.", comment: "")
        case .duplicateSource: NSLocalizedString("This provider list URL has already been added.", comment: "")
        case .invalidOptions: NSLocalizedString("The selected upload options are unavailable.", comment: "")
        case .missingBundle: NSLocalizedString("The app bundle could not be found.", comment: "")
        case .emptyFile: NSLocalizedString("The IPA or manifest is missing or empty.", comment: "")
        case .tooLarge: NSLocalizedString("This file exceeds the provider’s upload limit.", comment: "")
        case .unsafeSymlink: NSLocalizedString("The app bundle has a link to a file outside the bundle.", comment: "")
        case .invalidLink: NSLocalizedString("The provider did not return a direct HTTPS file link.", comment: "")
        case .invalidDownload: NSLocalizedString("The hosted link did not serve the uploaded IPA.", comment: "")
        case .invalidManifest: NSLocalizedString("The hosted link did not serve the uploaded installation manifest.", comment: "")
        case .http(let status):
            String(format: NSLocalizedString("The server returned HTTP %d.", comment: ""), status)
        }
    }
}
