import AppKit

/// The app's version and the standard macOS About panel.
enum AppInfo {
    /// "0.1.1", or "development build" when run outside an app bundle (`swift run`).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// "Version 0.1.1 (1)", as shown in Settings and bug reports.
    static var versionLabel: String {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil else { return version.capitalized }
        return "Version \(version)" + (build.map { " (\($0))" } ?? "")
    }

    static let website = URL(string: "https://medaimane.github.io/headroom/")!
    static let guide = URL(string: "https://medaimane.github.io/headroom/guide/")!
    static let changelog = URL(string: "https://github.com/medaimane/headroom/blob/main/CHANGELOG.md")!
    static let newIssue = URL(string: "https://github.com/medaimane/headroom/issues/new/choose")!

    /// Shows the standard About panel with links. Opening a link is the user's click; Headroom itself makes no network calls.
    @MainActor
    static func showAboutPanel() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let text = NSMutableAttributedString(string: "Keep your dev Mac fast.\n", attributes: body)
        let links: [(String, URL)] = [("Website", website), ("Guide", guide), ("What's new", changelog), ("Report a bug", newIssue)]
        for (index, (title, url)) in links.enumerated() {
            var attributes = body
            attributes[.link] = url
            text.append(NSAttributedString(string: title, attributes: attributes))
            if index < links.count - 1 { text.append(NSAttributedString(string: "  ·  ", attributes: body)) }
        }
        text.append(NSAttributedString(string: "\nFree and open source under the MIT License.", attributes: body))
        return text
    }
}
