import Foundation

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    /// RAM and swap, in binary units like Activity Monitor (16 GB, not 17.18 GB).
    public static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func memory(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static let gigabyte: Int64 = 1_000_000_000
}

extension String {
    /// A string from a NUL-terminated C buffer.
    init(cBuffer: [CChar]) {
        self = String(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
