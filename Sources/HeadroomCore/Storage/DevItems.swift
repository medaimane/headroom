import Foundation

/// Large developer items that are not caches. Each one needs its own confirmation.
public enum DevItemKind: String, Codable, Sendable, CaseIterable {
    case simulatorRuntime
    case simulatorDevice
    case androidAVD
    case androidSystemImage
    case xcodeArchive

    public var title: String {
        switch self {
        case .simulatorRuntime: "Simulator runtimes"
        case .simulatorDevice: "Simulator devices"
        case .androidAVD: "Android virtual devices (AVDs)"
        case .androidSystemImage: "Android system images"
        case .xcodeArchive: "Xcode archives"
        }
    }

    public var removalNote: String {
        switch self {
        case .simulatorRuntime: "Deleted with `xcrun simctl runtime delete`. To get it back, download it again in Xcode ▸ Settings ▸ Components."
        case .simulatorDevice: "Deleted with `xcrun simctl delete`, including its installed apps and data. Recreate it in Xcode ▸ Devices and Simulators."
        case .androidAVD: "Moved to the Trash (the .avd folder and its .ini file). Put it back from the Trash to undo."
        case .androidSystemImage: "Moved to the Trash. Put it back from the Trash, or reinstall it in Android Studio ▸ SDK Manager."
        case .xcodeArchive: "Moved to the Trash. Put it back from the Trash to undo. Archives hold the dSYMs for crash reports of shipped builds."
        }
    }
}

public struct DevItem: Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: DevItemKind
    public var name: String
    public var detail: String
    public var bytes: Int64
    public var lastUsed: Date?
    public var isInUse: Bool
    /// Why it can't be removed right now, if it can't.
    public var blockedReason: String?
    public var location: URL?

    public init(id: String, kind: DevItemKind, name: String, detail: String, bytes: Int64, lastUsed: Date? = nil, isInUse: Bool = false, blockedReason: String? = nil, location: URL? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.isInUse = isInUse
        self.blockedReason = blockedReason
        self.location = location
    }
}

// MARK: - Parsing simctl output

public enum SimctlParser {
    struct RuntimeJSON: Decodable {
        var identifier: String
        var version: String?
        var build: String?
        var platformIdentifier: String?
        var runtimeIdentifier: String?
        var sizeBytes: Int64?
        var state: String?
        var deletable: Bool?
        var lastUsedAt: String?
    }

    struct DeviceListJSON: Decodable {
        var devices: [String: [DeviceJSON]]
    }

    struct DeviceJSON: Decodable {
        var udid: String
        var name: String
        var state: String?
        var isAvailable: Bool?
        var dataPathSize: Int64?
        var lastBootedAt: String?
        var dataPath: String?
    }

    /// Parses `xcrun simctl runtime list -j`.
    public static func runtimes(from json: String) throws -> [DevItem] {
        let decoded = try JSONDecoder().decode([String: RuntimeJSON].self, from: Data(json.utf8))
        return decoded.values.map { runtime in
            let platform = platformName(runtime.platformIdentifier ?? runtime.runtimeIdentifier ?? "")
            let name = "\(platform) \(runtime.version ?? "?")"
            let detail = [runtime.build.map { "Build \($0)" }, runtime.state].compactMap { $0 }.joined(separator: " · ")
            return DevItem(
                id: "runtime:\(runtime.identifier)",
                kind: .simulatorRuntime,
                name: name,
                detail: detail,
                bytes: runtime.sizeBytes ?? 0,
                lastUsed: runtime.lastUsedAt.flatMap(parseDate),
                blockedReason: runtime.deletable == false ? "macOS marks this runtime as not deletable." : nil
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Parses `xcrun simctl list devices -j`.
    public static func devices(from json: String) throws -> [DevItem] {
        let decoded = try JSONDecoder().decode(DeviceListJSON.self, from: Data(json.utf8))
        return decoded.devices.flatMap { runtimeKey, devices in
            devices.map { device in
                let booted = device.state == "Booted"
                let runtime = runtimeLabel(runtimeKey)
                var detail = runtime
                if device.isAvailable == false { detail += " · runtime missing" }
                return DevItem(
                    id: "device:\(device.udid)",
                    kind: .simulatorDevice,
                    name: device.name,
                    detail: detail,
                    bytes: device.dataPathSize ?? 0,
                    lastUsed: device.lastBootedAt.flatMap(parseDate),
                    isInUse: booted,
                    blockedReason: booted ? "This simulator is running. Shut it down first." : nil,
                    location: device.dataPath.map { URL(fileURLWithPath: $0) }
                )
            }
        }
        .sorted { $0.bytes > $1.bytes }
    }

    static func platformName(_ identifier: String) -> String {
        let lower = identifier.lowercased()
        if lower.contains("iphone") || lower.contains("ios") { return "iOS" }
        if lower.contains("watch") { return "watchOS" }
        if lower.contains("appletv") || lower.contains("tvos") { return "tvOS" }
        if lower.contains("xr") || lower.contains("vision") { return "visionOS" }
        return identifier
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2" → "iOS 27.2"
    static func runtimeLabel(_ key: String) -> String {
        guard let last = key.split(separator: ".").last else { return key }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return key }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Scanning

public struct DevItemScanner: Sendable {
    public var paths: HostPaths
    public var runner: CommandRunning

    public init(paths: HostPaths, runner: CommandRunning = ProcessCommandRunner()) {
        self.paths = paths
        self.runner = runner
    }

    public func simulatorRuntimes() async -> Result<[DevItem], Error> {
        await Result.asyncCatching { () async throws -> [DevItem] in
            let result = try await runner.run(ToolLocator.xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
            guard result.succeeded else { throw ScanError.commandFailed("simctl runtime list") }
            return try SimctlParser.runtimes(from: result.stdout)
        }
    }

    public func simulatorDevices() async -> Result<[DevItem], Error> {
        await Result.asyncCatching { () async throws -> [DevItem] in
            let result = try await runner.run(ToolLocator.xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
            guard result.succeeded else { throw ScanError.commandFailed("simctl list devices") }
            return try SimctlParser.devices(from: result.stdout)
        }
    }

    /// AVDs are listed by folder name only. Their config files are not read.
    public func androidAVDs(emulatorRunning: Bool) -> [DevItem] {
        let avdRoot = paths.home.appending(path: ".android/avd", directoryHint: .isDirectory)
        let items = (try? FileManager.default.contentsOfDirectory(at: avdRoot, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "avd" }.map { url in
            let size = DirectorySizer.measure(url)
            let name = url.deletingPathExtension().lastPathComponent
            return DevItem(
                id: "avd:\(name)", kind: .androidAVD, name: name.replacingOccurrences(of: "_", with: " "),
                detail: url.lastPathComponent, bytes: size.bytes, lastUsed: size.newestModification,
                isInUse: emulatorRunning,
                blockedReason: emulatorRunning ? "An Android emulator is running. Close it first." : nil,
                location: url
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    public func androidSystemImages() -> [DevItem] {
        let root = paths.androidSDK.appending(path: "system-images", directoryHint: .isDirectory)
        var items: [DevItem] = []
        let fm = FileManager.default
        for api in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for tag in (try? fm.contentsOfDirectory(at: api, includingPropertiesForKeys: nil)) ?? [] {
                for abi in (try? fm.contentsOfDirectory(at: tag, includingPropertiesForKeys: nil)) ?? [] {
                    guard (try? abi.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let size = DirectorySizer.measure(abi)
                    let label = "\(api.lastPathComponent) · \(tag.lastPathComponent) · \(abi.lastPathComponent)"
                    items.append(DevItem(id: "sysimg:\(label)", kind: .androidSystemImage, name: api.lastPathComponent.replacingOccurrences(of: "android-", with: "API "),
                                         detail: "\(tag.lastPathComponent) · \(abi.lastPathComponent)", bytes: size.bytes, lastUsed: size.newestModification, location: abi))
                }
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    public func xcodeArchives() -> [DevItem] {
        let root = paths.home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory)
        var items: [DevItem] = []
        let fm = FileManager.default
        for day in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for archive in (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [] where archive.pathExtension == "xcarchive" {
                let size = DirectorySizer.measure(archive)
                items.append(DevItem(id: "archive:\(day.lastPathComponent)/\(archive.lastPathComponent)", kind: .xcodeArchive,
                                     name: archive.deletingPathExtension().lastPathComponent, detail: day.lastPathComponent,
                                     bytes: size.bytes, lastUsed: size.newestModification, location: archive))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// The allow-listed folders that per-item "move to Trash" may act inside.
    public func trashableRoots() -> [URL] {
        [
            paths.home.appending(path: ".android/avd", directoryHint: .isDirectory),
            paths.androidSDK.appending(path: "system-images", directoryHint: .isDirectory),
            paths.home.appending(path: "Library/Developer/Xcode/Archives", directoryHint: .isDirectory),
        ]
    }
}

public enum ScanError: Error, CustomStringConvertible {
    case commandFailed(String)
    public var description: String {
        switch self {
        case .commandFailed(let command): "\(command) failed."
        }
    }
}

extension Result where Failure == Error {
    static func asyncCatching(_ body: () async throws -> Success) async -> Result {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

// MARK: - Docker

public struct DockerUsageRow: Sendable, Hashable, Identifiable {
    public var id: String { type }
    public var type: String
    public var total: String
    public var active: String
    public var size: String
    public var reclaimable: String
}

public enum DockerUsage {
    public enum Status: Sendable {
        case notInstalled
        case notRunning
        case rows([DockerUsageRow])
    }

    /// `docker system df` over the local Docker socket. Read-only; no network.
    public static func read(paths: HostPaths, runner: CommandRunning) async -> Status {
        guard let docker = ToolLocator.docker(home: paths.home) else { return .notInstalled }
        guard let result = try? await runner.run(docker, ["system", "df", "--format", "{{json .}}"], environment: ToolLocator.cleanEnvironment(home: paths.home), timeout: 10),
              result.succeeded else { return .notRunning }
        return .rows(parse(result.stdout))
    }

    public static func parse(_ output: String) -> [DockerUsageRow] {
        output.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            func string(_ key: String) -> String { (object[key] as? String) ?? (object[key].map { "\($0)" } ?? "") }
            return DockerUsageRow(type: string("Type"), total: string("TotalCount"), active: string("Active"), size: string("Size"), reclaimable: string("Reclaimable"))
        }
    }
}
