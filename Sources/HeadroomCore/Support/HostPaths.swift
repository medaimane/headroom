import Foundation

/// The locations Headroom works with. Everything is derived from these roots so tests
/// (and the debug app) can point the whole app at a fixture "home" folder.
public struct HostPaths: Sendable, Hashable {
    /// The user's home folder (or a fixture folder that stands in for it).
    public var home: URL
    /// The per-user temporary folder (`$TMPDIR`), where Metro keeps its caches.
    public var temporary: URL
    /// The Android SDK root.
    public var androidSDK: URL
    /// True when `home` is a fixture override inside a temporary folder.
    public var isFixture: Bool

    public init(home: URL, temporary: URL, androidSDK: URL? = nil, isFixture: Bool = false) {
        self.home = home
        self.temporary = temporary
        self.androidSDK = androidSDK ?? home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        self.isFixture = isFixture
    }

    /// The real paths, unless `HEADROOM_HOME` points at a fixture folder inside a temporary directory.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> HostPaths {
        let realTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if let override = environment["HEADROOM_HOME"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isInsideTemporaryLocation(url) {
                return HostPaths(home: url, temporary: url.appending(path: "tmp", directoryHint: .isDirectory), isFixture: true)
            }
        }
        return HostPaths(home: FileManager.default.homeDirectoryForCurrentUser, temporary: realTemp)
    }

    /// The folder where Headroom keeps its settings, history and snapshots.
    public var supportDirectory: URL {
        home.appending(path: "Library/Application Support/Headroom", directoryHint: .isDirectory)
    }

    /// Whether a URL resolves to somewhere inside `/private/tmp`, `/private/var/folders` or `$TMPDIR`.
    public static func isInsideTemporaryLocation(_ url: URL) -> Bool {
        guard let resolved = Canonical.path(of: url) else { return false }
        var roots = ["/private/tmp", "/private/var/folders"]
        if let tmp = Canonical.path(of: URL(fileURLWithPath: NSTemporaryDirectory())) { roots.append(tmp) }
        return roots.contains { resolved.hasPrefix($0 + "/") }
    }
}

/// Canonical (symlink-free, absolute) paths via `realpath(3)`.
///
/// Foundation's `resolvingSymlinksInPath()` strips `/private` from some paths, which would
/// make prefix checks unreliable, so path checks always go through here.
public enum Canonical {
    /// The canonical path of an existing file or folder, or nil if it doesn't exist.
    public static func path(of url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The canonical path of an item without following the item itself if it is a symlink:
    /// the parent folder is resolved and the last component is appended as-is.
    public static func pathWithoutFollowingLast(of url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != ".", last != "..", last != "/" else { return nil }
        guard let parent = path(of: url.deletingLastPathComponent()) else { return nil }
        return parent == "/" ? "/" + last : parent + "/" + last
    }

    /// True when `path` is strictly inside `root` (not equal to it).
    public static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}
