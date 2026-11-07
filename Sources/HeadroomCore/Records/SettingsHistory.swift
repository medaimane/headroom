import Foundation

/// Turns a change of settings into History entries, one per setting, with how to change it back.
public enum SettingsHistory {
    /// The entry for turning dry run on or off. Recorded right away, because it decides whether clean-ups delete for real.
    public static func dryRunEntry(isOn: Bool, date: Date = Date()) -> HistoryEntry {
        HistoryEntry(
            date: date,
            action: isOn ? "Dry run turned on" : "Dry run turned off",
            detail: isOn ? "Clean-ups only simulate; nothing is deleted." : "Clean-ups now delete for real, after your review and click.",
            bytes: 0, dryRun: false, succeeded: true,
            undo: isOn ? "Turn it off in Settings ▸ Clean-up." : "Turn dry run back on in Settings ▸ Clean-up."
        )
    }

    /// One entry per changed setting between `old` and `new`, in the order Settings shows them.
    public static func entries(from old: HeadroomSettings, to new: HeadroomSettings, date: Date = Date()) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []

        func add(_ name: String, section: String, _ before: String, _ after: String) {
            guard before != after else { return }
            entries.append(HistoryEntry(
                date: date, action: "Setting changed: \(name)", detail: "\(before) → \(after)",
                bytes: 0, dryRun: false, succeeded: true,
                undo: "Set it back to \(before) in Settings ▸ \(section)."
            ))
        }
        func gb(_ bytes: Int64) -> String { "\(bytes / Format.gigabyte) GB" }
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }

        add("Disk warning", section: "Disk", gb(old.diskWarningBytes), gb(new.diskWarningBytes))
        add("Disk critical", section: "Disk", gb(old.diskCriticalBytes), gb(new.diskCriticalBytes))
        add("Free-space target", section: "Disk", gb(old.diskTargetBytes), gb(new.diskTargetBytes))
        add("Swap warning", section: "Memory", gb(old.swapWarningBytes), gb(new.swapWarningBytes))
        add("Swap critical", section: "Memory", gb(old.swapCriticalBytes), gb(new.swapCriticalBytes))
        add("Memory pressure notice", section: "Memory",
            "\(Int(old.pressureSustainSeconds / 60)) min", "\(Int(new.pressureSustainSeconds / 60)) min")
        add("Sample interval", section: "Memory", "\(Int(old.sampleIntervalSeconds)) s", "\(Int(new.sampleIntervalSeconds)) s")
        add("Notifications", section: "Memory", onOff(old.notificationsEnabled), onOff(new.notificationsEnabled))
        if old.dryRun != new.dryRun { entries.append(dryRunEntry(isOn: new.dryRun, date: date)) }
        add("Worktree folders", section: "Worktrees",
            old.worktreeRoots.joined(separator: ", "), new.worktreeRoots.joined(separator: ", "))
        return entries
    }
}
