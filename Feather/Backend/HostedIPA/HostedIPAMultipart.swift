import Foundation

/// A disk-backed request body keeps large IPAs out of memory.
struct HostedIPAMultipart {
    enum FileKind: Sendable {
        case ipa, manifest

        func filename(for provider: UploadProvider) -> String {
            self == .ipa ? provider.upload.ipaFilename : provider.upload.manifestFilename
        }
        var contentType: String { self == .ipa ? "application/octet-stream" : "text/xml" }
    }

    let url: URL
    let boundary: String
    let length: Int64

    static func accepts(size: Int64, provider: UploadProvider, choices: [String: String]) -> Bool {
        guard provider.accepts(size: size) else { return false }
        guard let limit = provider.requestLimitBytes else { return true }
        // UUID boundaries all have the same length.
        let boundary = "Feather-00000000-0000-0000-0000-000000000000"
        guard let (prefix, suffix) = try? envelope(boundary: boundary, kind: .ipa, provider: provider, choices: choices) else {
            return false
        }
        return size <= limit - Int64(prefix.count + suffix.count)
    }

    private static func envelope(boundary: String, kind: FileKind, provider: UploadProvider,
                                 choices: [String: String]) throws -> (Data, Data) {
        guard let fileField = provider.upload.fileField else { throw HostedIPAError.invalidCatalog }
        let fields = try provider.fields(choices: choices)
        var prefix = Data()
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            prefix.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8)
        }
        prefix.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(kind.filename(for: provider))\"\r\nContent-Type: \(kind.contentType)\r\n\r\n".utf8)
        return (prefix, Data("\r\n--\(boundary)--\r\n".utf8))
    }

    static func write(file: URL, kind: FileKind, provider: UploadProvider, choices: [String: String]) throws -> Self {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count > 0 else {
            throw HostedIPAError.emptyFile
        }
        let size = Int64(count)
        guard provider.accepts(size: size) else { throw HostedIPAError.tooLarge }
        let boundary = "Feather-\(UUID().uuidString)"
        let (prefix, suffix) = try envelope(boundary: boundary, kind: kind, provider: provider, choices: choices)
        let (length, overflow) = size.addingReportingOverflow(Int64(prefix.count + suffix.count))
        guard !overflow, provider.requestLimitBytes.map({ length <= $0 }) ?? true else { throw HostedIPAError.tooLarge }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            try prefix.write(to: url)
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try output.seekToEnd()
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(remaining, 256 * 1024))), !chunk.isEmpty else {
                    throw HostedIPAError.emptyFile
                }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try output.write(contentsOf: suffix)
            return .init(url: url, boundary: boundary, length: length)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
