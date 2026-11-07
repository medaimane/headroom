import Foundation

/// What a process is, from the point of view of a mobile and web developer.
public enum ProcessCategory: String, Codable, CaseIterable, Sendable, Comparable {
    case iosSimulator
    case androidEmulator
    case claudeAgent
    case claudeApp
    case metro
    case nextjs
    case buildsAndTests
    case nodeOther
    case watchman
    case gradle
    case xcode
    case ide
    case containers
    case browser
    case system
    case other

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .iosSimulator: "iOS Simulator"
        case .androidEmulator: "Android emulator"
        case .claudeAgent: "Claude Code agents"
        case .claudeApp: "Claude app"
        case .metro: "Metro"
        case .nextjs: "Next.js"
        case .buildsAndTests: "Nx, builds and tests"
        case .nodeOther: "Other Node.js"
        case .watchman: "Watchman"
        case .gradle: "Gradle and JVM"
        case .xcode: "Xcode and Swift tools"
        case .ide: "Editors and IDEs"
        case .containers: "Docker and VMs"
        case .browser: "Browsers"
        case .system: "macOS"
        case .other: "Other apps"
        }
    }

    public var symbol: String {
        switch self {
        case .iosSimulator: "iphone"
        case .androidEmulator: "candybarphone"
        case .claudeAgent: "sparkles"
        case .claudeApp: "bubble.left.and.text.bubble.right"
        case .metro: "tram"
        case .nextjs: "globe"
        case .buildsAndTests: "hammer"
        case .nodeOther: "chevron.left.forwardslash.chevron.right"
        case .watchman: "eye"
        case .gradle: "cup.and.saucer"
        case .xcode: "swift"
        case .ide: "pencil.and.outline"
        case .containers: "shippingbox"
        case .browser: "safari"
        case .system: "apple.logo"
        case .other: "app"
        }
    }

    /// Categories that are test devices.
    public var isTestDevice: Bool { self == .iosSimulator || self == .androidEmulator }

    /// Categories whose processes belong to running work (devices, agents, dev servers).
    /// Headroom never stops these without an explicit confirmation.
    public var isProtectedWork: Bool {
        switch self {
        case .iosSimulator, .androidEmulator, .claudeAgent, .metro, .nextjs, .buildsAndTests, .gradle, .containers: true
        default: false
        }
    }
}

/// What the categorizer looks at. Arguments are used only to classify and are never stored
/// or shown, because command lines can contain tokens.
public struct ProcessIdentity: Sendable {
    public var name: String
    public var path: String
    public var arguments: [String]

    public init(name: String, path: String, arguments: [String] = []) {
        self.name = name
        self.path = path
        self.arguments = arguments
    }
}

public enum ProcessCategorizer {
    public static func categorize(_ identity: ProcessIdentity) -> ProcessCategory {
        let path = identity.path
        let name = identity.name.isEmpty ? (path as NSString).lastPathComponent : identity.name
        let lowerPath = path.lowercased()
        let args = identity.arguments.joined(separator: " ")

        // Claude Code agent sessions (the CLI, wherever it was installed from).
        if lowerPath.contains("/claude-code/") || name == "claude" || lowerPath.hasSuffix("/claude")
            || args.contains("@anthropic-ai/claude-code") {
            return .claudeAgent
        }
        if path.contains("/Claude.app/") { return .claudeApp }

        // Test devices.
        if path.contains("/CoreSimulator/") || path.contains("/Simulator.app/") || name == "launchd_sim" {
            return .iosSimulator
        }
        if name.hasPrefix("qemu-system") || name == "emulator" || name.hasPrefix("emulator-") || name == "netsimd" {
            if lowerPath.contains("/android/") || lowerPath.contains("/emulator/") { return .androidEmulator }
            return .containers
        }
        if name == "adb" { return .androidEmulator }

        // Containers and virtual machines.
        if path.contains("/Docker.app/") || path.contains("/OrbStack.app/") || name.hasPrefix("com.docker.")
            || ["colima", "limactl", "lima", "vpnkit", "OrbStack", "orbstack", "orbstack-helper", "podman", "com.apple.Virtualization.VirtualMachine"].contains(name) {
            return .containers
        }

        // Node-based dev servers and tools.
        if name.hasPrefix("next-server") || name.hasPrefix("next-router-worker") { return .nextjs }
        if isNodeLike(name: name, path: path) {
            return categorizeNode(args: args)
        }

        if name == "watchman" { return .watchman }
        if name == "java" || name == "KotlinCompileDaemon" || lowerPath.contains("/gradle") {
            if path.contains("/Android Studio.app/") && !args.contains("GradleDaemon") && !args.contains("KotlinCompileDaemon") {
                return .ide
            }
            return .gradle
        }

        if path.contains("/Xcode.app/") || path.contains("/Xcode-") || ["xcodebuild", "XCBBuildService", "SWBBuildService", "SourceKitService", "swift-frontend", "swift-build", "clang", "ld", "sourcekit-lsp"].contains(name) {
            return .xcode
        }
        if path.contains("/Android Studio.app/") || path.contains("/Visual Studio Code.app/") || path.contains("/Cursor.app/")
            || path.contains("/Zed.app/") || path.contains("/Windsurf.app/") || path.contains("/Sublime Text.app/") {
            return .ide
        }

        let browserBundles = ["/Google Chrome.app/", "/Safari.app/", "/Arc.app/", "/Firefox.app/", "/Brave Browser.app/",
                              "/Microsoft Edge.app/", "/Chromium.app/", "/Vivaldi.app/", "/Opera.app/", "/Comet.app/", "/Dia.app/",
                              "/Google Chrome Canary.app/", "/Firefox Developer Edition.app/", "/Safari Technology Preview.app/"]
        if browserBundles.contains(where: path.contains) || name.hasPrefix("com.apple.WebKit.") {
            return .browser
        }

        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/")
            || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/System/Volumes/Preboot/Cryptexes/") {
            return .system
        }
        return .other
    }

    static func isNodeLike(name: String, path: String) -> Bool {
        ["node", "bun", "deno"].contains(name) || path.hasSuffix("/bin/node")
    }

    static func categorizeNode(args: String) -> ProcessCategory {
        let metroMarkers = ["react-native start", "react-native/cli", "@react-native/community-cli-plugin", "metro/src", "/metro/", "expo start", "rn-cli"]
        if metroMarkers.contains(where: args.contains) { return .metro }
        let nextMarkers = ["next dev", "next start", "/next/dist/", "next-server", "/.bin/next"]
        if nextMarkers.contains(where: args.contains) { return .nextjs }
        let buildMarkers = ["/nx/", "/.bin/nx", "nx/bin", "@nx/", "jest", "vitest", "tsc", "typescript/lib", "eslint", "webpack", "esbuild", "turbo", "playwright", "detox", "cdk", "aws-cdk"]
        if buildMarkers.contains(where: args.contains) { return .buildsAndTests }
        return .nodeOther
    }
}
