// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StradaMAM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StradaMAMCore", targets: ["StradaMAMCore"]),
        .library(name: "StradaMAMMedia", targets: ["StradaMAMMedia"]),
        .library(name: "StradaMAMAI", targets: ["StradaMAMAI"]),
        .library(name: "StradaMAMRemote", targets: ["StradaMAMRemote"]),
        .executable(name: "stradaxr-ingest", targets: ["stradaxr-ingest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Platform-independent: catalog, timecode, proxy planning, relink logic.
        // Builds and is tested on Linux as well as macOS.
        .target(
            name: "StradaMAMCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "CSQLiteLinuxShim", condition: .when(platforms: [.linux])),
            ]
        ),
        // Linker stubs for SQLite symbols missing from Ubuntu's SQLite. Unused on macOS.
        .target(name: "CSQLiteLinuxShim"),
        // Ingest, proxy rendering, thumbnails and source recall, driven through FFmpeg.
        .target(
            name: "StradaMAMMedia",
            dependencies: ["StradaMAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS only (Vision / Speech): transcription, faces, scene and text recognition.
        .target(
            name: "StradaMAMAI",
            dependencies: ["StradaMAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS only (Network.framework): the read-only proxy server editors connect to.
        .target(
            name: "StradaMAMRemote",
            dependencies: [
                "StradaMAMCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The headless ingest client: watches folders, catalogues clips and renders proxies.
        .executableTarget(
            name: "stradaxr-ingest",
            dependencies: ["StradaMAMMedia"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "StradaMAMCoreTests", dependencies: ["StradaMAMCore"]),
        .testTarget(name: "StradaMAMMediaTests", dependencies: ["StradaMAMMedia"]),
        .testTarget(name: "StradaMAMRemoteTests", dependencies: ["StradaMAMRemote"]),
        .testTarget(name: "StradaMAMAITests", dependencies: ["StradaMAMAI", "StradaMAMMedia"]),
    ]
)
