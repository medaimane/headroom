# Changelog

All notable changes to Headroom are listed here. Versions follow [semantic versioning](https://semver.org): 0.x.y while the app is young, with minor versions for new features and patch versions for fixes.

Downloads are on the [releases page](https://github.com/medaimane/headroom/releases).

## [Unreleased]

## [0.2.0] - 2026-11-07

### Added
- **Dev environment page:** booted simulators, running emulators, dev servers with the ports they listen on, and Claude Code agent sessions per worktree. Stop a simulator (`simctl shutdown`), emulator or dev server after its own confirmation: always a normal stop request, never a force-quit, and only if it's still the same process. Agent sessions are shown but never stopped. `headroom-cli dev` prints the same report.
- **Remove node_modules from old worktrees:** on the Worktrees page, remove a worktree's `node_modules` with one confirmation each, only when the worktree is clean and pushed, git ignores the folder, and nothing is running from it. Everything is checked again right before removal, and History says how to reinstall. `headroom-cli node-modules` shows which pass the checks, without removing anything.

### Changed
- **Menu bar icon:** the Headroom mark replaces the generic gauge. It adapts to light and dark menu bars and gains an outlined or filled "!" badge for warning and critical states.

## [0.1.1] - 2026-11-07

### Added
- **About Headroom:** the version, with links to the website, guide, changelog and bug reports. Open it from the ⓘ button in the menu bar panel or from Settings, which now also shows the version.

### Changed
- **Faster scans:** folder sizes are measured with a lighter file walk, and worktrees six at a time. On a Mac with 39 worktrees the full worktree report went from about 95 to 30 seconds, and storage and device scans are quicker too.

### Fixed
- **History now records settings changes,** as it says it does. Turning dry run on or off is recorded straight away; other settings are recorded once you stop adjusting them, as one entry like "Disk warning: 60 GB → 85 GB" with how to set it back.

## [0.1.0] - 2026-11-07

The first public release.

### Added
- **Menu bar:** free disk, memory pressure, swap, CPU and thermal state at a glance, with a warning icon when something needs attention.
- **Health:** an hour of live charts, and memory and CPU grouped by what's running: iOS Simulator, Android emulator, Claude Code agents (one row per worktree), Metro, Next.js, builds and tests, Gradle, Xcode, IDEs, Docker and VMs, and browsers.
- **Storage:** sizes of 20 known developer caches against a free-space target, with a review-then-confirm clean-up. Dry run is on by default, and caches are skipped while their tool runs.
- **Simulators and devices:** simulator runtimes and devices, Android AVDs and system images, and Xcode archives, each removed only after its own confirmation (`xcrun simctl` or move to Trash).
- **Explore:** a read-only, size-sorted view of your home folder.
- **Worktrees:** branch, uncommitted changes, unpushed commits, and node_modules and Nx cache size for every git worktree. Read-only.
- **Workload snapshots:** record a named workload and keep its peaks.
- **History:** every action with when, how big and how to undo it, exportable as Markdown.
- **Warnings:** notifications for low disk, sustained memory pressure, heavy swap and throttling.
- **`headroom-cli`:** read-only reports for health, processes, storage, devices, worktrees and a dry-run plan.
- A universal download (Apple silicon and Intel), plus a website and guide.

[Unreleased]: https://github.com/medaimane/headroom/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/medaimane/headroom/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/medaimane/headroom/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/medaimane/headroom/releases/tag/v0.1.0
