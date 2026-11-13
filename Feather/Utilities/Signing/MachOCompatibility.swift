import Foundation

/// Bounds-checked inspection of load commands and fat slices; never executes input.
enum MachOCompatibility {
    struct Slice { let offset: Int; let size: Int; let cpu: UInt32; let subtype: UInt32 }
    private static func word(_ data: Data, _ offset: Int, little: Bool) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
        let bytes = data[offset..<(offset + 4)]
        return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func invalid() -> Error { EntitlementPolicy.Failure(message: "Malformed Mach-O header or load command.") }

    static func slices(_ data: Data) throws -> [Slice] {
        guard data.count >= 4 else { return [] }
        let magic = try word(data, 0, little: false)
        if [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(try word(data, 4, little: little))
            let stride = wide ? 32 : 20
            guard count > 0, count <= (data.count - 8) / stride else { throw invalid() }
            return try (0..<count).map { index in
                let base = 8 + index * stride
                func integer(_ offset: Int) throws -> UInt64 {
                    let high = UInt64(try word(data, offset, little: little))
                    guard wide else { return high }
                    let low = UInt64(try word(data, offset + 4, little: little))
                    return little ? (low << 32) | high : (high << 32) | low
                }
                let offset = try integer(base + 8)
                let size = try integer(base + (wide ? 16 : 12))
                guard offset >= UInt64(8 + count * stride), offset <= UInt64(data.count),
                      size >= 28, size <= UInt64(data.count) - offset else { throw invalid() }
                return Slice(offset: Int(offset), size: Int(size), cpu: try word(data, base, little: little), subtype: try word(data, base + 4, little: little))
            }
        }
        guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { return [] }
        let little = magic == 0xcefaedfe || magic == 0xcffaedfe
        guard data.count >= 28 else { throw invalid() }
        return [Slice(offset: 0, size: data.count, cpu: try word(data, 4, little: little), subtype: try word(data, 8, little: little))]
    }

    static func encrypted(_ data: Data) throws -> Bool {
        for slice in try slices(data) {
            let base = slice.offset
            let magic = try word(data, base, little: false)
            guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { throw invalid() }
            let little = magic == 0xcefaedfe || magic == 0xcffaedfe
            let header = (magic == 0xfeedfacf || magic == 0xcffaedfe) ? 32 : 28
            let count = Int(try word(data, base + 16, little: little))
            let size = Int(try word(data, base + 20, little: little))
            guard header <= slice.size, size <= slice.size - header, count <= size / 8 else { throw invalid() }
            var offset = base + header
            let end = offset + size
            for _ in 0..<count {
                guard offset <= end - 8 else { throw invalid() }
                let command = try word(data, offset, little: little)
                let length = Int(try word(data, offset + 4, little: little))
                guard length >= 8, length <= end - offset else { throw invalid() }
                if command == 0x21 || command == 0x2c {
                    guard length >= (command == 0x2c ? 24 : 20) else { throw invalid() }
                    if try word(data, offset + 16, little: little) != 0 { return true }
                }
                offset += length
            }
        }
        return false
    }

    static func arm64(_ data: Data) throws -> Data {
        let architectures = try slices(data)
        guard !architectures.isEmpty else { return data }
        guard let selected = architectures.filter({ $0.cpu == 0x0100000c }).min(by: { ($0.subtype & 0xffffff) < ($1.subtype & 0xffffff) }) else {
            throw EntitlementPolicy.Failure(message: "A binary has no arm64 slice. Remove incompatible Watch apps or disable Thin to arm64.")
        }
        let result = data.subdata(in: selected.offset..<(selected.offset + selected.size))
        _ = try encrypted(result) // Validate inner header/load commands before replacing the file.
        return result
    }
}
