import Foundation
import HeadroomCore

// A read-only command-line companion. It reports; it never cleans or changes anything.

let usage = """
headroom-cli: read-only reports from Headroom's core.

  health       memory, swap, CPU, thermal state and disk
  processes    memory and CPU grouped by what's running
  storage      sizes of the known developer cache locations
  devices      simulator runtimes and devices, AVDs, system images, archives
  worktrees    git worktrees under ~/Developer with branch and push status
  node-modules which worktrees' node_modules pass every removal check (checks only)
  plan [ids]   what a clean-up of the given cache ids would remove (dry run)
"""

let paths = HostPaths.current()
let settings = SettingsStore(directory: paths.supportDirectory).load()
let arguments = Array(CommandLine.arguments.dropFirst())

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func lpad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

switch arguments.first {
case "health":
    var reader = SystemMetricsReader(volume: paths.home)
    _ = reader.sample()
    try await Task.sleep(for: .seconds(1))
    let sample = reader.sample()
    let hw = HardwareInfo.current()
    let assessment = HealthAssessment(sample: sample, settings: settings)
    print("\(hw.chip), \(Format.memory(hw.memory)) memory, \(hw.performanceCores)P+\(hw.efficiencyCores)E cores")
    print("Disk free        \(Format.bytes(sample.diskFree)) of \(Format.bytes(sample.diskTotal)) (with purgeable: \(Format.bytes(sample.diskFreeIncludingPurgeable)))  [\(assessment.disk)]")
    print("Memory used      \(Format.memory(sample.memoryUsed)) (compressed \(Format.memory(sample.memoryCompressed)), wired \(Format.memory(sample.memoryWired)))")
    print("Memory pressure  \(sample.pressure.label)  [\(assessment.memory)]")
    print("Swap             \(Format.memory(sample.swapUsed)) of \(Format.memory(sample.swapTotal))  [\(assessment.swap)]")
    print("CPU              \(Format.percent(sample.cpuUsage))")
    print("Thermal          \(sample.thermal.label)  [\(assessment.thermal)]")

case "processes":
    let sampler = ProcessSampler()
    _ = sampler.sample()
    try await Task.sleep(for: .seconds(2))
    let snapshot = sampler.sample()
    print("\(snapshot.testDeviceCount) test devices, \(snapshot.agentSessionCount) agent sessions, \(snapshot.unreadableCount) system processes not readable\n")
    for group in snapshot.groups {
        print(pad(group.category.title, 26) + lpad(Format.memory(group.memory), 10) + lpad(Format.percent(group.cpu), 7) + "  (\(group.processes.count))")
        for sub in group.subgroups.prefix(4) {
            print("    " + pad(String(sub.title.prefix(40)), 42) + lpad(Format.memory(sub.memory), 10))
        }
    }

case "storage":
    var total: Int64 = 0
    for entry in StorageCatalog.entries {
        let size: DirectorySize
        switch entry.location {
        case .temporaryPrefix:
            let parts = entry.targets(in: paths).map { DirectorySizer.measure($0) }
            size = DirectorySize(bytes: parts.reduce(0) { $0 + $1.bytes }, fileCount: 0, newestModification: nil, partial: false)
        default:
            size = DirectorySizer.measure(entry.root(in: paths))
        }
        if entry.kind == .rebuildableCache { total += size.bytes }
        let kind = entry.kind == .rebuildableCache ? "cache" : "info "
        print(pad(entry.id, 22) + kind + "  " + pad(entry.name, 44) + lpad(Format.bytes(size.bytes), 10) + (size.partial ? "  (partial)" : ""))
    }
    print("\nRebuildable caches in total: \(Format.bytes(total))")
    switch await DockerUsage.read(paths: paths, runner: ProcessCommandRunner()) {
    case .notInstalled: print("Docker: not installed")
    case .notRunning: print("Docker: not running")
    case .rows(let rows): for row in rows { print("Docker \(row.type): \(row.size), reclaimable \(row.reclaimable)") }
    }

case "devices":
    let scanner = DevItemScanner(paths: paths)
    var items: [DevItem] = []
    if case .success(let runtimes) = await scanner.simulatorRuntimes() { items += runtimes }
    if case .success(let devices) = await scanner.simulatorDevices() { items += devices }
    items += scanner.androidAVDs(emulatorRunning: false) + scanner.androidSystemImages() + scanner.xcodeArchives()
    for kind in DevItemKind.allCases {
        let group = items.filter { $0.kind == kind }
        print("\n\(kind.title): \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))")
        for item in group {
            let used = item.lastUsed.map { "used " + Format.relative($0) } ?? ""
            print("  " + pad(String(item.name.prefix(34)), 36) + pad(String(item.detail.prefix(34)), 36) + lpad(Format.bytes(item.bytes), 10) + "  " + used)
        }
    }

case "worktrees":
    let scanner = WorktreeScanner(paths: paths)
    let worktrees = await scanner.scan(roots: settings.worktreeRootURLs(home: paths.home))
    for info in worktrees.sorted(by: { ($0.nodeModulesBytes ?? 0) > ($1.nodeModulesBytes ?? 0) }) {
        let path = info.path.replacingOccurrences(of: paths.home.path, with: "~")
        print(pad(info.status.label, 18) + pad(String((info.branch ?? "detached").prefix(40)), 42)
              + "unpushed " + lpad(info.unpushedCommits.map(String.init) ?? "-", 3)
              + "  changes " + lpad(info.uncommittedChanges.map(String.init) ?? "-", 4)
              + "  node_modules " + lpad(info.nodeModulesBytes.map { Format.bytes($0) } ?? "-", 9)
              + "  " + path)
    }
    print("\n\(worktrees.count) worktrees. Push status is as of the last git fetch.")

case "node-modules":
    let worktrees = await WorktreeScanner(paths: paths).scan(roots: settings.worktreeRootURLs(home: paths.home))
    let cleanup = NodeModulesCleanup(paths: paths, mode: .dryRun)
    var removable: Int64 = 0
    for info in worktrees.sorted(by: { ($0.nodeModulesBytes ?? 0) > ($1.nodeModulesBytes ?? 0) }) where (info.nodeModulesBytes ?? 0) > 0 {
        let size = info.nodeModulesBytes ?? 0
        let verdict: String
        switch await cleanup.verify(worktree: info.path) {
        case .success:
            removable += size
            verdict = "removable"
        case .failure(let blocker):
            verdict = "keep: " + blocker.description
        }
        print(lpad(Format.bytes(size), 9) + "  " + pad(String((info.branch ?? "detached").prefix(36)), 38) + verdict)
    }
    print("\nChecks only: nothing was removed. \(Format.bytes(removable)) of node_modules passes every check.")

case "plan":
    let ids = arguments.count > 1 ? Array(arguments.dropFirst()) : StorageCatalog.cleanable.map(\.id)
    let sampler = ProcessSampler()
    let running = RunningWork(records: sampler.sample().records)
    let plan = CleanupPlanner(paths: paths).plan(entryIDs: ids, running: running)
    for item in plan.items {
        if let reason = item.blockedReason {
            print(pad(item.entry.name, 34) + "SKIP  \(reason)")
        } else {
            print(pad(item.entry.name, 34) + lpad(Format.bytes(item.bytes), 10) + "  \(item.targets.count) items")
        }
    }
    print("\nDry run only. A clean-up would free about \(Format.bytes(plan.bytes)). Nothing was changed.")

default:
    print(usage)
}
