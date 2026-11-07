import Foundation

/// How Headroom treats a location.
public enum StorageKind: String, Codable, Sendable {
    /// A cache its tool rebuilds by itself. Can be cleaned after one confirmation.
    case rebuildableCache
    /// Shown with size and location only. Headroom never changes it.
    case infoOnly
}

public enum CatalogLocation: Sendable, Hashable {
    /// A folder under the home folder, whose contents are the cache.
    case home(String)
    /// A folder under the Android SDK, whose contents are the cache.
    case androidSDK(String)
    /// Items directly in `$TMPDIR` whose names start with this prefix.
    case temporaryPrefix(String)
}

/// One known location on the allow-list.
public struct CatalogEntry: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var group: String
    public var location: CatalogLocation
    public var kind: StorageKind
    /// What happens after cleaning, in plain words.
    public var rebuildNote: String
    /// Cleaning is refused while any of these are running.
    public var blockingCategories: Set<ProcessCategory>
    public var blockingProcessNames: Set<String>

    public init(id: String, name: String, group: String, location: CatalogLocation, kind: StorageKind = .rebuildableCache, rebuildNote: String, blockingCategories: Set<ProcessCategory> = [], blockingProcessNames: Set<String> = []) {
        self.id = id
        self.name = name
        self.group = group
        self.location = location
        self.kind = kind
        self.rebuildNote = rebuildNote
        self.blockingCategories = blockingCategories
        self.blockingProcessNames = blockingProcessNames
    }

    /// The folder this entry lives in (for prefix entries, `$TMPDIR`).
    public func root(in paths: HostPaths) -> URL {
        switch location {
        case .home(let relative): paths.home.appending(path: relative, directoryHint: .isDirectory)
        case .androidSDK(let relative): paths.androidSDK.appending(path: relative, directoryHint: .isDirectory)
        case .temporaryPrefix: paths.temporary
        }
    }

    /// The items that cleaning this entry would remove: the root's children, or the matching `$TMPDIR` items.
    public func targets(in paths: HostPaths) -> [URL] {
        let root = root(in: paths)
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        switch location {
        case .temporaryPrefix(let prefix):
            return children.filter { $0.lastPathComponent.hasPrefix(prefix) }
        default:
            return children
        }
    }
}

/// The allow-list. Headroom cleans nothing that isn't here.
public enum StorageCatalog {
    public static let entries: [CatalogEntry] = [
        // Xcode
        CatalogEntry(id: "xcode.derivedData", name: "Xcode DerivedData", group: "Xcode", location: .home("Library/Developer/Xcode/DerivedData"),
                     rebuildNote: "Xcode rebuilds it. The next build of each project is a full build, and Swift packages are fetched again.",
                     blockingProcessNames: ["xcodebuild", "XCBBuildService", "SWBBuildService"]),
        CatalogEntry(id: "xcode.deviceSupport", name: "iOS DeviceSupport", group: "Xcode", location: .home("Library/Developer/Xcode/iOS DeviceSupport"),
                     rebuildNote: "Xcode copies the symbols again the next time you connect a physical device. That can take several minutes.",
                     blockingProcessNames: ["Xcode"]),
        CatalogEntry(id: "xcode.cache", name: "Xcode caches", group: "Xcode", location: .home("Library/Caches/com.apple.dt.Xcode"),
                     rebuildNote: "Xcode recreates it as you work.", blockingProcessNames: ["Xcode"]),
        CatalogEntry(id: "xcode.previews", name: "SwiftUI Previews data", group: "Xcode", location: .home("Library/Developer/Xcode/UserData/Previews"),
                     rebuildNote: "Previews are rebuilt the next time you open them.", blockingProcessNames: ["Xcode"]),
        CatalogEntry(id: "swiftpm.cache", name: "Swift Package Manager cache", group: "Xcode", location: .home("Library/Caches/org.swift.swiftpm"),
                     rebuildNote: "Packages are downloaded again on the next resolve (needs network).",
                     blockingProcessNames: ["xcodebuild", "swift-build", "swift-package"]),

        // iOS Simulator
        CatalogEntry(id: "simulator.caches", name: "Simulator caches", group: "iOS Simulator", location: .home("Library/Developer/CoreSimulator/Caches"),
                     rebuildNote: "Rebuilt on the next simulator boot, so the first boot is slower.",
                     blockingCategories: [.iosSimulator]),

        // Android
        CatalogEntry(id: "gradle.caches", name: "Gradle caches", group: "Android", location: .home(".gradle/caches"),
                     rebuildNote: "Dependencies are downloaded again on the next Android build. The first build is slower and needs network.",
                     blockingCategories: [.gradle]),
        CatalogEntry(id: "gradle.wrapper", name: "Gradle wrapper downloads", group: "Android", location: .home(".gradle/wrapper/dists"),
                     rebuildNote: "Each project's Gradle version is downloaded again on its next build (needs network).",
                     blockingCategories: [.gradle]),
        CatalogEntry(id: "android.cache", name: "Android build cache", group: "Android", location: .home(".android/cache"),
                     rebuildNote: "Recreated by the Android tools on the next build.", blockingCategories: [.gradle]),

        // JavaScript and React Native
        CatalogEntry(id: "npm.cache", name: "npm cache", group: "JavaScript", location: .home(".npm/_cacache"),
                     rebuildNote: "Packages are downloaded again on the next install (needs network)."),
        CatalogEntry(id: "yarn.classic", name: "Yarn cache (v1)", group: "JavaScript", location: .home("Library/Caches/Yarn"),
                     rebuildNote: "Packages are downloaded again on the next install (needs network)."),
        CatalogEntry(id: "yarn.berry", name: "Yarn cache (Berry)", group: "JavaScript", location: .home(".yarn/berry/cache"),
                     rebuildNote: "Packages are downloaded again on the next install (needs network)."),
        CatalogEntry(id: "pnpm.store", name: "pnpm store", group: "JavaScript", location: .home("Library/pnpm/store"),
                     rebuildNote: "Packages are downloaded again on the next install. Existing node_modules keep working, so little space is freed until they're reinstalled."),
        CatalogEntry(id: "cocoapods.cache", name: "CocoaPods cache", group: "JavaScript", location: .home("Library/Caches/CocoaPods"),
                     rebuildNote: "pod install downloads specs and pods again (needs network).", blockingProcessNames: ["pod"]),
        CatalogEntry(id: "metro.cache", name: "Metro cache", group: "JavaScript", location: .temporaryPrefix("metro-"),
                     rebuildNote: "Metro rebuilds it. The next bundle after starting Metro is slower.", blockingCategories: [.metro]),
        CatalogEntry(id: "haste.cache", name: "Haste map cache", group: "JavaScript", location: .temporaryPrefix("haste-map-"),
                     rebuildNote: "Metro and Jest rebuild it on their next run.", blockingCategories: [.metro, .buildsAndTests]),
        CatalogEntry(id: "nodegyp.cache", name: "node-gyp headers", group: "JavaScript", location: .home("Library/Caches/node-gyp"),
                     rebuildNote: "Downloaded again the next time a native module builds (needs network)."),
        CatalogEntry(id: "playwright.cache", name: "Playwright browsers", group: "JavaScript", location: .home("Library/Caches/ms-playwright"),
                     rebuildNote: "Run `npx playwright install` again before the next Playwright run (needs network).",
                     blockingCategories: [.buildsAndTests]),
        CatalogEntry(id: "typescript.cache", name: "TypeScript type cache", group: "JavaScript", location: .home("Library/Caches/typescript"),
                     rebuildNote: "Editors download type definitions again as needed."),

        // Homebrew
        CatalogEntry(id: "homebrew.cache", name: "Homebrew downloads", group: "Homebrew", location: .home("Library/Caches/Homebrew"),
                     rebuildNote: "Only old download files. Installed tools are not affected; reinstalling one downloads it again."),

        // Shown, never cleaned
        CatalogEntry(id: "info.trash", name: "Trash", group: "Other", location: .home(".Trash"), kind: .infoOnly,
                     rebuildNote: "Emptying the Trash deletes files for good, so Headroom leaves it to you (Finder ▸ Empty Trash)."),
        CatalogEntry(id: "info.logs", name: "Logs", group: "Other", location: .home("Library/Logs"), kind: .infoOnly,
                     rebuildNote: "Shown by size only. Logs can contain private data, so Headroom never opens or deletes them."),
        CatalogEntry(id: "info.caches", name: "All app caches (includes the caches above)", group: "Other", location: .home("Library/Caches"), kind: .infoOnly,
                     rebuildNote: "Every app's caches together. Headroom only cleans the known developer caches listed above."),
        CatalogEntry(id: "info.claude", name: "Claude Code data", group: "Other", location: .home(".claude"), kind: .infoOnly,
                     rebuildNote: "Session transcripts and settings. Not a cache."),
    ]

    public static func entry(_ id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    public static var cleanable: [CatalogEntry] { entries.filter { $0.kind == .rebuildableCache } }
}
