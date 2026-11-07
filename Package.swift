// swift-tools-version: 6.0
import PackageDescription

let debugDefine: [SwiftSetting] = [.define("DEBUG", .when(configuration: .debug))]

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
        .executable(name: "headroom-cli", targets: ["headroom-cli"]),
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
    ],
    targets: [
        .target(name: "HeadroomCore", swiftSettings: debugDefine),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"], swiftSettings: debugDefine),
        .executableTarget(name: "headroom-cli", dependencies: ["HeadroomCore"], swiftSettings: debugDefine),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ]
)
