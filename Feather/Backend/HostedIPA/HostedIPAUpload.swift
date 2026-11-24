import Foundation

enum HostedIPAUpload {
    struct HTTPError: LocalizedError {
        let status: Int
        let retryAt: Date?

        init(_ response: HTTPURLResponse) {
            status = response.statusCode
            retryAt = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
        }

        var errorDescription: String? { HostedIPAError.http(status).errorDescription }

        private static func retryDate(_ header: String?) -> Date? {
            guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let seconds = UInt64(value) {
                return min(Date.now.addingTimeInterval(TimeInterval(seconds)), .distantFuture)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let formats = ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"]
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            return nil
        }
    }

    static func send(file: URL, kind: HostedIPAMultipart.FileKind, provider: UploadProvider, choices: [String: String],
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let body = try HostedIPAMultipart.write(file: file, kind: kind, provider: provider, choices: choices)
        defer { try? FileManager.default.removeItem(at: body.url) }
        try Task.checkCancellation()

        let delegate = SessionDelegate(progress: progress)
        let session = makeSession(delegate: delegate, resourceTimeout: 6 * 60 * 60)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: provider.upload.url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
        request.setValue(userAgent(for: provider), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.upload(for: request, fromFile: body.url)
        let http = try httpResponse(response)
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(http) }
        return try provider.downloadURL(from: data)
    }

    static func checkIPA(_ link: URL, provider: UploadProvider, localFile: URL, size: Int64) async throws {
        guard provider.allowsDownload(link) else { throw HostedIPAError.invalidLink }
        let input = try FileHandle(forReadingFrom: localFile)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 4) ?? Data()
        guard prefix == Data([0x50, 0x4B, 0x03, 0x04]) else { throw HostedIPAError.invalidDownload }

        var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(userAgent(for: provider), forHTTPHeaderField: "User-Agent")
        try await checkDownload(request) { stream, http in
            if http.statusCode == 206 {
                let range = http.value(forHTTPHeaderField: "Content-Range")?.lowercased()
                guard range == "bytes 0-3/\(size)" else { throw HostedIPAError.invalidDownload }
            } else if http.statusCode == 200 {
                // Some hosts ignore Range. Read only the ZIP header and cancel the rest.
                let length = http.expectedContentLength
                guard length < 0 || length == size else { throw HostedIPAError.invalidDownload }
            } else {
                throw HTTPError(http)
            }
            var sample = Data()
            for try await byte in stream {
                sample.append(byte)
                if sample.count == prefix.count { break }
            }
            guard sample == prefix else { throw HostedIPAError.invalidDownload }
        }
    }

    static func checkManifest(_ link: URL, provider: UploadProvider, expected: Data) async throws {
        guard provider.allowsDownload(link) else { throw HostedIPAError.invalidLink }
        var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(userAgent(for: provider), forHTTPHeaderField: "User-Agent")
        try await checkDownload(request) { stream, http in
            guard http.statusCode == 200 else { throw HTTPError(http) }
            guard provider.download.manifestMIMETypes.contains(http.mimeType?.lowercased() ?? "") else {
                throw HostedIPAError.invalidManifest
            }
            var data = Data()
            for try await byte in stream {
                guard data.count < expected.count else { throw HostedIPAError.invalidManifest }
                data.append(byte)
            }
            guard data == expected else { throw HostedIPAError.invalidManifest }
        }
    }

    static func fetchCatalog(_ url: URL) async throws -> UploadProviderCatalog {
        guard UploadProviderCatalog.isHTTPS(url) else { throw HostedIPAError.invalidSourceURL }
        let session = makeSession(delegate: SessionDelegate(), resourceTimeout: 25)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        let http = try httpResponse(response)
        guard http.statusCode == 200 else { throw HostedIPAError.http(http.statusCode) }
        var data = Data()
        for try await byte in stream {
            guard data.count < UploadProviderCatalog.maximumBytes else { throw HostedIPAError.invalidCatalog }
            data.append(byte)
        }
        return try UploadProviderCatalog.decode(data)
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw HostedIPAError.invalidLink }
        return http
    }

    private static func checkDownload(_ request: URLRequest,
                                      validate: (URLSession.AsyncBytes, HTTPURLResponse) async throws -> Void) async throws {
        func attempt() async throws {
            let session = makeSession(delegate: SessionDelegate(), resourceTimeout: 25)
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(for: request)
            try await validate(stream, httpResponse(response))
        }

        // Newly published links can take time to become reachable. Only retry their GET requests.
        for fallback: TimeInterval in [1, 3] {
            do {
                try await attempt()
                return
            } catch let error as HTTPError where [404, 429, 500, 502, 503, 504].contains(error.status) {
                let delay = max(fallback, error.retryAt?.timeIntervalSinceNow ?? 0)
                guard delay <= 10 else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        try await attempt()
    }

    private static func userAgent(for provider: UploadProvider) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "FeatherForkVersion") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return provider.userAgent(bundleID: bundle.bundleIdentifier ?? "thewonderofyou.Feather", version: version)
    }

    private static func makeSession(delegate: SessionDelegate, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(90, resourceTimeout)
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private final class SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // URLSession delivers delegate calls on its serial delegate queue.
        private var lastPercent = -1
        let progress: (@Sendable (Double) -> Void)?

        init(progress: (@Sendable (Double) -> Void)? = nil) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // These links must work as direct requests from the iOS installer.
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            let percent = Int(min(100, 100 * Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
            guard percent > lastPercent else { return }
            lastPercent = percent
            progress?(Double(percent) / 100)
        }
    }
}
