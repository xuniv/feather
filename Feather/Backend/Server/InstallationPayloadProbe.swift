import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Verify real file bytes, not HEAD's expected response-body length.
enum InstallationPayloadProbe {
    struct Sample: Sendable {
        let size: UInt64
        let firstByte: Data

        init(file: URL) throws {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            firstByte = try handle.read(upToCount: 1) ?? Data()
            guard size > 0, firstByte.count == 1 else {
                throw InstallationTransport.Failure(message: "The generated IPA file is empty.")
            }
        }
    }

    static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("1", forHTTPHeaderField: InstallationTransport.preflightHeader)
        return request
    }

    static func validateResponse(_ response: URLResponse, sample: Sample) throws {
        guard let http = response as? HTTPURLResponse else {
            throw InstallationTransport.Failure(message: "The local IPA endpoint returned a non-HTTP response.")
        }
        guard http.statusCode == 206 else {
            throw InstallationTransport.Failure(message: "The local IPA range check returned HTTP \(http.statusCode), expected 206.")
        }
        let range = http.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard range == "bytes 0-0/\(sample.size)" else {
            throw InstallationTransport.Failure(message: "The local IPA range response does not match the generated file size.")
        }
    }

    static func validateBody(_ data: Data, sample: Sample) throws {
        guard data == sample.firstByte else {
            throw InstallationTransport.Failure(message: "The local IPA range response does not match the generated file bytes.")
        }
    }

    #if !canImport(FoundationNetworking)
    // AsyncBytes is the Darwin URLSession API used by the iOS app. Reject a
    // server ignoring Range before consuming its body, and retain at most 1 byte.
    static func check(url: URL, sample: Sample) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request(url: url))
        try validateResponse(response, sample: sample)
        var data = Data()
        for try await byte in bytes {
            guard data.isEmpty else {
                throw InstallationTransport.Failure(message: "The local IPA range response exceeded the one-byte probe limit.")
            }
            data.append(byte)
        }
        try validateBody(data, sample: sample)
    }
    #endif
}
