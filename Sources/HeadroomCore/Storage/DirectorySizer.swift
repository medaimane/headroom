import Foundation

public struct DirectorySize: Sendable, Equatable, Codable {
    /// Allocated bytes on disk. APFS clones and hard links can make this an overestimate.
    public var bytes: Int64
    public var fileCount: Int
    public var newestModification: Date?
    /// True when some items couldn't be read (for example without Full Disk Access).
    public var partial: Bool

    public static let empty = DirectorySize(bytes: 0, fileCount: 0, newestModification: nil, partial: false)

    public init(bytes: Int64, fileCount: Int, newestModification: Date?, partial: Bool) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestModification = newestModification
        self.partial = partial
    }
}

/// Measures folders by walking them. Only reads metadata (sizes and dates), never file contents.
/// Symlinked folders are not followed.
public enum DirectorySizer {
    private static let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]

    public static func measure(_ url: URL, isCancelled: @Sendable () -> Bool = { false }) -> DirectorySize {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .empty }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            return DirectorySize(bytes: size, fileCount: 1, newestModification: values?.contentModificationDate, partial: false)
        }

        let partialFlag = PartialFlag()
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
            partialFlag.value = true
            return true
        }) else {
            return DirectorySize(bytes: 0, fileCount: 0, newestModification: nil, partial: true)
        }

        var total: Int64 = 0
        var count = 0
        var newest: Date?
        for case let item as URL in enumerator {
            if count % 2048 == 0, isCancelled() { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                count += 1
            }
            if let date = values.contentModificationDate, date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return DirectorySize(bytes: total, fileCount: count, newestModification: newest, partial: partialFlag.value)
    }

    /// Sizes of the direct children of a folder, largest first. For the "explore" drill-down.
    public static func children(of url: URL, isCancelled: @Sendable () -> Bool = { false }) -> [(url: URL, size: DirectorySize)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .map { ($0, measure($0, isCancelled: isCancelled)) }
            .sorted { $0.size.bytes > $1.size.bytes }
    }
}

private final class PartialFlag: @unchecked Sendable {
    var value = false
}
