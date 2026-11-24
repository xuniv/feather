import Foundation

enum HostedIPAUpload {
    struct HTTPError: LocalizedError {
        let status: Int
        let retryAt: Date?
        let waitingForFile2MeScan: Bool

        init(_ response: HTTPURLResponse, waitingForFile2MeScan: Bool = false) {
            status = response.statusCode
            retryAt = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
            self.waitingForFile2MeScan = waitingForFile2MeScan
        }

        var errorDescription: String? {
            if waitingForFile2MeScan {
                return NSLocalizedString("file2.me is still scanning this file. Retry to check the same link again.", comment: "")
            }
            return HostedIPAError.http(status).errorDescription
        }

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
        if provider.usesFile2Me {
            return try await sendFile2Me(file: file, kind: kind, provider: provider, choices: choices, progress: progress)
        }
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

    private static func sendFile2Me(file: URL, kind: HostedIPAMultipart.FileKind, provider: UploadProvider,
                                   choices: [String: String], progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { throw HostedIPAError.emptyFile }
        guard provider.accepts(size: Int64(bytes)) else { throw HostedIPAError.tooLarge }
        let expiry = try provider.fields(choices: choices)["expiry"] ?? "24h"
        guard File2Me.expiries.contains(expiry) else { throw HostedIPAError.invalidOptions }

        let session = makeSession(delegate: SessionDelegate(), resourceTimeout: 25)
        defer { session.invalidateAndCancel() }
        let agent = userAgent(for: provider)
        func post<Reply: Decodable>(_ type: Reply.Type, to url: URL, fields: [String: Any]) async throws -> Reply {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
            let (stream, response) = try await session.bytes(for: request)
            let http = try httpResponse(response)
            guard (200..<300).contains(http.statusCode) else { throw HTTPError(http) }
            var data = Data()
            for try await byte in stream {
                guard data.count < 64 * 1024 else { throw HostedIPAError.invalidLink }
                data.append(byte)
            }
            return try JSONDecoder().decode(type, from: data)
        }

        let fileDetails: [String: Any] = ["filename": kind.filename(for: provider), "size": bytes, "contentType": kind.contentType]
        let reservation = try await post(File2Me.Reservation.self, to: File2Me.presign,
                                         fields: fileDetails.merging(["destination": "share"]) { current, _ in current })
        guard File2Me.allowsStorageURL(reservation.presignedUrl) else { throw HostedIPAError.invalidLink }
        var put = URLRequest(url: reservation.presignedUrl)
        put.httpMethod = "PUT"
        put.setValue(kind.contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
        put.setValue(agent, forHTTPHeaderField: "User-Agent")
        let transfer = makeSession(delegate: SessionDelegate(progress: progress), resourceTimeout: 6 * 60 * 60)
        defer { transfer.finishTasksAndInvalidate() }
        let (_, response) = try await transfer.upload(for: put, fromFile: file)
        let http = try httpResponse(response)
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(http) }

        let confirmation = try await post(File2Me.Confirmation.self, to: File2Me.confirm,
                                          fields: fileDetails.merging(["storageKey": reservation.storageKey,
                                                                      "uploadGrant": reservation.uploadGrant]) { current, _ in current })
        let result = try await post(File2Me.Share.self, to: File2Me.share,
                                    fields: ["fileIds": [confirmation.file.id], "expiry": expiry])
        return try File2Me.rawURL(shareID: result.share.id)
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
        try await checkDownload(request, provider: provider) { stream, http in
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
        try await checkDownload(request, provider: provider) { stream, http in
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

    private static func checkDownload(_ request: URLRequest, provider: UploadProvider,
                                      validate: (URLSession.AsyncBytes, HTTPURLResponse) async throws -> Void) async throws {
        func attempt() async throws {
            let session = makeSession(delegate: SessionDelegate(), resourceTimeout: 25)
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(for: request)
            let http = try httpResponse(response)
            if provider.usesFile2Me, let raw = request.url {
                if http.statusCode == 423 { throw HTTPError(http, waitingForFile2MeScan: true) }
                if http.statusCode == 307 {
                    let storage = try File2Me.storageRedirect(from: raw, status: http.statusCode,
                                                             location: http.value(forHTTPHeaderField: "Location"))
                    // Verify this response's signed target once. The /raw URL stays valid for the share's lifetime.
                    var redirected = request
                    redirected.url = storage
                    let (body, response) = try await session.bytes(for: redirected)
                    try await validate(body, httpResponse(response))
                    return
                }
            }
            try await validate(stream, http)
        }

        // Newly published links can take time to become reachable. Only retry their GET requests.
        let delays: [TimeInterval] = provider.usesFile2Me ? [1, 3, 6, 10, 15, 20] : [1, 3]
        for (index, fallback) in delays.enumerated() {
            do {
                try await attempt()
                return
            } catch let error as HTTPError where error.waitingForFile2MeScan ||
                    (index < 2 && [404, 429, 500, 502, 503, 504].contains(error.status)) {
                let delay = max(fallback, error.retryAt?.timeIntervalSinceNow ?? 0)
                guard delay <= (error.waitingForFile2MeScan ? 20 : 10) else { throw error }
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
            // The file2.me download check validates and follows its one storage redirect explicitly.
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
