// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StadaMAM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StadaMAMCore", targets: ["StadaMAMCore"]),
        .library(name: "StadaMAMMedia", targets: ["StadaMAMMedia"]),
        .library(name: "StadaMAMAI", targets: ["StadaMAMAI"]),
        .library(name: "StadaMAMRemote", targets: ["StadaMAMRemote"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Platform-independent: catalog, timecode, proxy planning, relink logic.
        // Builds and is tested on Linux as well as macOS.
        .target(
            name: "StadaMAMCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "CSQLiteLinuxShim", condition: .when(platforms: [.linux])),
            ]
        ),
        // Linker stubs for SQLite symbols missing from Ubuntu's SQLite. Unused on macOS.
        .target(name: "CSQLiteLinuxShim"),
        // Ingest, proxy rendering, thumbnails and source recall, driven through FFmpeg.
        .target(
            name: "StadaMAMMedia",
            dependencies: ["StadaMAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS only (Vision / Speech): transcription, faces, scene and text recognition.
        .target(
            name: "StadaMAMAI",
            dependencies: ["StadaMAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS only (Network.framework): the read-only proxy server editors connect to.
        .target(
            name: "StadaMAMRemote",
            dependencies: [
                "StadaMAMCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "StadaMAMCoreTests", dependencies: ["StadaMAMCore"]),
        .testTarget(name: "StadaMAMMediaTests", dependencies: ["StadaMAMMedia"]),
        .testTarget(name: "StadaMAMRemoteTests", dependencies: ["StadaMAMRemote"]),
        .testTarget(name: "StadaMAMAITests", dependencies: ["StadaMAMAI", "StadaMAMMedia"]),
    ]
)
