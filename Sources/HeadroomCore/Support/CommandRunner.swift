import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum CommandError: Error, CustomStringConvertible {
    case notFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notFound(let tool): "\(tool) was not found on this Mac."
        case .launchFailed(let detail): "Could not start the command: \(detail)"
        }
    }
}

/// Runs external commands. Tests swap in a fake.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await run(executable, arguments, environment: nil, timeout: timeout)
    }
}

/// Runs a real process, with a timeout. Never uses a shell, so arguments are never interpreted.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw CommandError.notFound(executable) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CommandError.launchFailed(String(describing: error)))
                    return
                }
                let box = ProcessBox(process)
                let killer = DispatchWorkItem {
                    if box.process.isRunning {
                        box.timedOut = true
                        box.process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self),
                    timedOut: box.timedOut
                ))
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    var timedOut = false
    init(_ process: Process) { self.process = process }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Finds developer tools without relying on a shell PATH (apps launched from Finder don't get one).
public enum ToolLocator {
    public static let xcrun = "/usr/bin/xcrun"
    public static let git = "/usr/bin/git"

    public static func docker(home: URL) -> String? {
        first(of: [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            home.appending(path: ".orbstack/bin/docker").path,
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ])
    }

    public static func first(of candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A minimal environment for child processes: no inherited secrets, no interactive prompts.
    public static func cleanEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
    }
}
