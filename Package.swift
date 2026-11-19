// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReelMAM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReelMAMCore", targets: ["ReelMAMCore"]),
        .library(name: "ReelMAMMedia", targets: ["ReelMAMMedia"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Platform-independent: catalog, timecode, proxy planning, relink logic.
        // Builds and is tested on Linux as well as macOS.
        .target(
            name: "ReelMAMCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "CSQLiteLinuxShim", condition: .when(platforms: [.linux])),
            ]
        ),
        // Linker stubs for SQLite symbols missing from Ubuntu's SQLite. Unused on macOS.
        .target(name: "CSQLiteLinuxShim"),
        // Ingest, proxy rendering, thumbnails and source recall, driven through FFmpeg.
        .target(
            name: "ReelMAMMedia",
            dependencies: ["ReelMAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ReelMAMCoreTests", dependencies: ["ReelMAMCore"]),
        .testTarget(name: "ReelMAMMediaTests", dependencies: ["ReelMAMMedia"]),
    ]
)
