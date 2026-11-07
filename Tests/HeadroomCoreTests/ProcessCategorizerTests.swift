import Darwin
import Testing
@testable import HeadroomCore

@Suite("Process categories")
struct ProcessCategorizerTests {
    func category(_ name: String, _ path: String, _ args: [String] = []) -> ProcessCategory {
        ProcessCategorizer.categorize(ProcessIdentity(name: name, path: path, arguments: args))
    }

    @Test func claudeCodeAgentFromTheDesktopApp() {
        #expect(category("claude", "/Users/me/Library/Application Support/Claude/claude-code/2.1.317/91184d3d9ba3/claude.app/Contents/MacOS/claude") == .claudeAgent)
    }

    @Test func claudeCodeAgentFromNpm() {
        #expect(category("node", "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claudeAgent)
    }

    @Test func claudeDesktopApp() {
        #expect(category("Claude Helper", "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") == .claudeApp)
    }

    @Test func iosSimulator() {
        #expect(category("launchd_sim", "/Library/Developer/CoreSimulator/Volumes/iOS_23A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim") == .iosSimulator)
        #expect(category("Simulator", "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator") == .iosSimulator)
    }

    @Test func androidEmulatorVersusContainerQemu() {
        #expect(category("qemu-system-aarch64", "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64") == .androidEmulator)
        #expect(category("qemu-system-aarch64", "/opt/homebrew/Cellar/qemu/9.0/bin/qemu-system-aarch64") == .containers)
    }

    @Test func devServers() {
        #expect(category("node", "/usr/local/bin/node", ["node", "/repo/node_modules/.bin/react-native", "start", "--port", "8081"]) == .metro)
        #expect(category("node", "/usr/local/bin/node", ["node", "/repo/node_modules/@react-native/community-cli-plugin/dist/start"]) == .metro)
        #expect(category("next-server (v15.2.0)", "/usr/local/bin/node") == .nextjs)
        #expect(category("node", "/usr/local/bin/node", ["node", "/repo/node_modules/next/dist/bin/next", "dev"]) == .nextjs)
        #expect(category("node", "/usr/local/bin/node", ["node", "/repo/node_modules/nx/bin/nx.js", "test", "mobile"]) == .buildsAndTests)
        #expect(category("node", "/usr/local/bin/node", ["node", "server.js"]) == .nodeOther)
    }

    @Test func gradleAndIDEs() {
        #expect(category("java", "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java", ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]) == .gradle)
        #expect(category("java", "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java", ["java", "com.intellij.idea.Main"]) == .ide)
        #expect(category("SourceKitService", "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/SourceKitService") == .xcode)
    }

    @Test func browsersAndSystem() {
        #expect(category("Google Chrome Helper (Renderer)", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == .browser)
        #expect(category("com.apple.WebKit.WebContent", "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent") == .browser)
        #expect(category("watchman", "/opt/homebrew/bin/watchman") == .watchman)
        #expect(category("mds_stores", "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores") == .system)
        #expect(category("Slack", "/Applications/Slack.app/Contents/MacOS/Slack") == .other)
    }

    @Test func agentsAreGroupedByWorktree() {
        let records = [
            ProcessRecord(pid: 1, name: "claude", category: .claudeAgent, memory: 300, cpu: 0.1, workingDirectory: "/Users/me/dev/eddii-frontend/.claude/worktrees/feature-a"),
            ProcessRecord(pid: 2, name: "claude", category: .claudeAgent, memory: 200, cpu: 0.2, workingDirectory: "/Users/me/dev/eddii-frontend/.claude/worktrees/feature-b"),
            ProcessRecord(pid: 3, name: "node", category: .claudeAgent, memory: 50, cpu: 0, workingDirectory: "/Users/me/dev/eddii-frontend/.claude/worktrees/feature-a"),
            ProcessRecord(pid: 4, name: "Google Chrome", category: .browser, memory: 1000, cpu: 0.5),
        ]
        let groups = ProcessGroup.group(records)
        #expect(groups.first?.category == .browser)
        let agents = groups.first { $0.category == .claudeAgent }
        #expect(agents?.memory == 550)
        #expect(agents?.subgroups.map(\.title) == ["worktrees/feature-a", "worktrees/feature-b"])
        #expect(agents?.subgroups.first?.count == 2)
        let snapshot = ProcessSnapshot(records: records, groups: groups, unreadableCount: 0)
        #expect(snapshot.agentSessionCount == 2)
    }

    @Test func deviceCount() {
        let records = [
            ProcessRecord(pid: 1, name: "launchd_sim", category: .iosSimulator, memory: 1, cpu: 0),
            ProcessRecord(pid: 2, name: "launchd_sim", category: .iosSimulator, memory: 1, cpu: 0),
            ProcessRecord(pid: 3, name: "SpringBoard", category: .iosSimulator, memory: 1, cpu: 0),
            ProcessRecord(pid: 4, name: "qemu-system-aarch64", category: .androidEmulator, memory: 1, cpu: 0),
            ProcessRecord(pid: 5, name: "adb", category: .androidEmulator, memory: 1, cpu: 0),
        ]
        #expect(ProcessSnapshot(records: records, groups: [], unreadableCount: 0).testDeviceCount == 3)
    }

    @Test func samplerReadsThisProcess() {
        let snapshot = ProcessSampler().sample()
        #expect(snapshot.records.count > 10)
        #expect(snapshot.records.contains { $0.pid == getpid() && $0.memory > 0 })
    }
}
