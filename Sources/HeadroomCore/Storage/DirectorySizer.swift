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

        return walk(url.path, isCancelled: isCancelled)
    }

    /// Walks a folder with fts(3), reading only each item's metadata (lstat). Much faster than
    /// FileManager's enumerator on big trees such as node_modules, because no URL objects are built.
    /// FTS_PHYSICAL means symlinks are reported as links and never followed.
    private static func walk(_ path: String, isCancelled: @Sendable () -> Bool) -> DirectorySize {
        var total: Int64 = 0
        var count = 0
        var newest: timespec?
        var partial = false

        let handle: UnsafeMutablePointer<FTS>? = path.withCString { cPath in
            var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(arguments[0]) }
            return fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil)
        }
        guard let handle else { return DirectorySize(bytes: 0, fileCount: 0, newestModification: nil, partial: true) }
        defer { fts_close(handle) }

        var visited = 0
        while let entry = fts_read(handle) {
            visited += 1
            if visited % 2048 == 0, isCancelled() { break }
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue  // a folder seen again after its contents
            case FTS_DNR, FTS_ERR, FTS_NS:
                partial = true
                continue
            default:
                break
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            if info == FTS_F {
                total += Int64(stat.st_blocks) * 512
                count += 1
            }
            let modified = stat.st_mtimespec
            if newest.map({ modified.tv_sec > $0.tv_sec || (modified.tv_sec == $0.tv_sec && modified.tv_nsec > $0.tv_nsec) }) ?? true {
                newest = modified
            }
        }
        let date = newest.map { Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_nsec) / 1_000_000_000) }
        return DirectorySize(bytes: total, fileCount: count, newestModification: date, partial: partial)
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
