import Foundation

public enum GuardViolation: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case missing(String)
    case outsideAllowList(String)
    case rootIsSymlinked(String)
    case protectedLocation(String)
    case insideGitWorkingTree(String)
    case containsEnvLocalFile(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): "Not a valid path: \(path)"
        case .missing(let path): "No longer exists: \(path)"
        case .outsideAllowList(let path): "Not inside a known cache location: \(path)"
        case .rootIsSymlinked(let path): "A cache folder points somewhere else through a symlink, so it was skipped: \(path)"
        case .protectedLocation(let path): "Protected location: \(path)"
        case .insideGitWorkingTree(let path): "Inside a git working tree, which Headroom never touches: \(path)"
        case .containsEnvLocalFile(let path): "Contains a .env*.local file, which Headroom never touches: \(path)"
        }
    }
}

/// The last check before anything is removed. Every target must be strictly inside an
/// allow-listed root, the root must not be redirected by a symlink, and the target must not be
/// inside a git working tree or contain `.env*.local` files.
public struct PathGuard: Sendable {
    /// Canonical paths of the allowed roots, after checking they are not redirected.
    public let allowedRoots: [String]
    public let rejectedRoots: [GuardViolation]
    private let home: String
    /// `$TMPDIR`, where only top-level items with one of `temporaryPrefixes` are allowed.
    private let temporaryRoot: String?
    private let temporaryPrefixes: [String]

    /// - Parameters:
    ///   - roots: allow-listed folders, each with the base it's expected to sit under.
    public init(paths: HostPaths, roots: [URL], temporaryPrefixes: [String] = []) {
        let home = Canonical.path(of: paths.home) ?? paths.home.path
        self.home = home
        self.temporaryRoot = Canonical.path(of: paths.temporary)
        self.temporaryPrefixes = temporaryPrefixes.filter { $0.count >= 3 }
        var allowed: [String] = []
        var rejected: [GuardViolation] = []
        for root in roots {
            switch Self.validateRoot(root, home: home, paths: paths) {
            case .success(let path): allowed.append(path)
            case .failure(let violation): rejected.append(violation)
            }
        }
        allowedRoots = allowed
        rejectedRoots = rejected
    }

    /// A root is valid when it exists, is inside the home folder or `$TMPDIR`, is not one of them,
    /// and resolving symlinks doesn't move it (so a symlinked cache can't redirect a clean-up elsewhere).
    static func validateRoot(_ root: URL, home: String, paths: HostPaths) -> Result<String, GuardViolation> {
        let standardized = root.standardizedFileURL
        guard let resolved = Canonical.path(of: standardized) else { return .failure(.missing(root.path)) }
        let temp = Canonical.path(of: paths.temporary)
        let bases = [home, temp].compactMap { $0 }
        if bases.contains(resolved) || resolved == "/" { return .failure(.protectedLocation(root.path)) }

        // Expected = resolved base + the relative part, unchanged.
        let expected: String? = {
            for (base, baseURL) in [(home, paths.home), (temp, paths.temporary)] {
                guard let base else { continue }
                let basePath = baseURL.standardizedFileURL.path
                let rootPath = standardized.path
                if rootPath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") {
                    let relative = rootPath.dropFirst(basePath.hasSuffix("/") ? basePath.count : basePath.count + 1)
                    return base + "/" + relative
                }
            }
            return nil
        }()
        guard let expected else { return .failure(.outsideAllowList(root.path)) }
        let trimmedExpected = expected.hasSuffix("/") ? String(expected.dropLast()) : expected
        guard resolved == trimmedExpected else { return .failure(.rootIsSymlinked(root.path)) }
        return .success(resolved)
    }

    /// Checks one item that is about to be removed. Returns its canonical path.
    /// The item itself is not followed if it's a symlink: removing a symlink removes only the link.
    @discardableResult
    public func validate(_ target: URL, scanContents: Bool = true) throws(GuardViolation) -> String {
        guard let path = Canonical.pathWithoutFollowingLast(of: target.standardizedFileURL) else {
            throw .invalidPath(target.path)
        }
        guard FileManager.default.fileExists(atPath: path) || Self.isSymlink(path) else { throw .missing(target.path) }
        let insideRoot = allowedRoots.contains { Canonical.isStrictlyInside(path, $0) }
        let name = (path as NSString).lastPathComponent
        let matchesTemporaryPrefix = temporaryRoot.map { (path as NSString).deletingLastPathComponent == $0 } == true
            && temporaryPrefixes.contains { name.hasPrefix($0) }
        guard insideRoot || matchesTemporaryPrefix else { throw .outsideAllowList(target.path) }
        if path == home || path == "/" { throw .protectedLocation(target.path) }
        if Self.isEnvLocal(target.lastPathComponent) { throw .containsEnvLocalFile(target.path) }
        if let repo = Self.enclosingGitWorkingTree(of: path) { throw .insideGitWorkingTree(repo) }
        if scanContents, !Self.isSymlink(path), let found = Self.findEnvLocalFile(in: URL(fileURLWithPath: path)) {
            throw .containsEnvLocalFile(found)
        }
        return path
    }

    /// `.env.local`, `.env.development.local`, `.env.sandbox.local`, …
    public static func isEnvLocal(_ name: String) -> Bool {
        name.hasPrefix(".env") && name.hasSuffix(".local")
    }

    /// Walks up from the item's parent looking for a `.git` entry.
    static func enclosingGitWorkingTree(of path: String) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty, current != "/" {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func findEnvLocalFile(in url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else { return nil }
        for case let item as URL in enumerator where isEnvLocal(item.lastPathComponent) {
            return item.path
        }
        return nil
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
