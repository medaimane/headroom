import Foundation
@testable import HeadroomCore

/// A throwaway fake home folder in the temporary directory. Tests never touch the real home.
final class Fixture {
    let root: URL
    let paths: HostPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "headroom-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let temp = root.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        paths = HostPaths(home: home, temporary: temp, isFixture: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var home: URL { paths.home }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relative: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func symlink(_ relative: String, to destination: URL, in base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

/// Records commands instead of running them.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var response = CommandResult(status: 0, stdout: "")

    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { calls.append([executable] + arguments) }
        return response
    }
}

/// Records removals instead of performing them.
final class RecordingRemover: FileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var removed: [URL] = []
    private(set) var trashed: [URL] = []

    func removeItem(at url: URL) throws { lock.withLock { removed.append(url) } }
    func trashItem(at url: URL) throws { lock.withLock { trashed.append(url) } }
}
