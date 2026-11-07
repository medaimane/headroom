import Foundation
import Testing
@testable import HeadroomCore

@Suite("Settings history")
struct SettingsHistoryTests {
    @Test func noChangeMakesNoEntries() {
        #expect(SettingsHistory.entries(from: HeadroomSettings(), to: HeadroomSettings()).isEmpty)
    }

    @Test func oneEntryPerChangedSettingWithHowToUndo() {
        let old = HeadroomSettings()
        var new = old
        new.diskWarningBytes = 85 * Format.gigabyte
        new.sampleIntervalSeconds = 10
        new.worktreeRoots = ["Developer", "Projects"]

        let entries = SettingsHistory.entries(from: old, to: new)
        #expect(entries.map(\.action) == [
            "Setting changed: Disk warning",
            "Setting changed: Sample interval",
            "Setting changed: Worktree folders",
        ])
        #expect(entries[0].detail == "60 GB → 85 GB")
        #expect(entries[0].undo == "Set it back to 60 GB in Settings ▸ Disk.")
        #expect(entries[1].detail == "5 s → 10 s")
        #expect(entries[2].detail == "Developer → Developer, Projects")
        #expect(entries.allSatisfy { $0.succeeded && !$0.dryRun && $0.bytes == 0 })
    }

    @Test func dryRunEntrySaysWhatItMeans() {
        let off = SettingsHistory.dryRunEntry(isOn: false)
        #expect(off.action == "Dry run turned off")
        #expect(off.detail.contains("delete for real"))
        #expect(off.undo == "Turn dry run back on in Settings ▸ Clean-up.")

        var new = HeadroomSettings()
        new.dryRun = false
        #expect(SettingsHistory.entries(from: HeadroomSettings(), to: new).map(\.action) == ["Dry run turned off"])
    }

    @Test func togglesReadAsOnAndOff() {
        var new = HeadroomSettings()
        new.notificationsEnabled = false
        let entry = try! #require(SettingsHistory.entries(from: HeadroomSettings(), to: new).first)
        #expect(entry.detail == "on → off")
        #expect(entry.undo == "Set it back to on in Settings ▸ Memory.")
    }
}
