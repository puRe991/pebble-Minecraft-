// swift-tools-version: 6.0
// Pebble — a native Swift + Metal block-survival game.
//
// macOS: builds the full game (engine + AppKit/Metal app + test harness).
//   swift build -c release
// Windows/Linux (experimental — see WINDOWS.md): builds only the portable,
//   headless engine and its golden test harness. The AppKit/Metal app target
//   is macOS-only and is not added to the package off-Apple.
//   swift build -c release          (builds PebbleCore + pebsmoke)
//   swift run   -c release pebsmoke (runs the 456-check golden suite)

import PackageDescription

// The engine is portable; its only native binding is SQLite. Apple ships an
// `SQLite3` module, so on Apple platforms PebbleCore needs no extra dependency.
// Elsewhere it binds the system libsqlite3 through the CSQLite shim target.
let coreDependencies: [Target.Dependency] = [
    .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows, .android])),
]

var targets: [Target] = [
    // Vendored SQLite (public-domain amalgamation) for non-Apple platforms.
    // On macOS PebbleCore imports Apple's built-in `SQLite3` module instead and
    // this target is never compiled (the dependency below is macOS-excluded), so
    // the flagship macOS build stays Apple-frameworks-only.
    .target(
        name: "CSQLite",
        path: "Sources/CSQLite",
        sources: ["sqlite3.c"],
        publicHeadersPath: "include",
        cSettings: [
            .define("SQLITE_THREADSAFE", to: "1"),
        ]
    ),
    // the engine: headless-testable, no AppKit dependencies
    .target(
        name: "PebbleCore",
        dependencies: coreDependencies,
        path: "Sources/PebbleCore",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ]
    ),
    // headless smoke tests against the frozen golden baselines
    .executableTarget(
        name: "pebsmoke",
        dependencies: ["PebbleCore"],
        path: "Sources/pebsmoke",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // headless world-map renderer — drives the real worldgen and writes a
    // top-down BMP. Portable (PebbleCore + Foundation only), so it runs on
    // Windows/Linux and is the first thing you can *see* the engine produce
    // off-Apple. See WINDOWS.md.
    .executableTarget(
        name: "pebmap",
        dependencies: ["PebbleCore"],
        path: "Sources/pebmap",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// The app is an AppKit + MTKView (Metal) shell — Apple-only. A Windows/Linux
// front-end is a separate port (see WINDOWS.md); until then the app target is
// simply absent off-Apple so `swift build` compiles the portable engine + tests.
#if os(macOS)
targets.append(
    .executableTarget(
        name: "Pebble",
        dependencies: ["PebbleCore"],
        path: "Sources/Pebble",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("QuartzCore"),
            .linkedFramework("AVFoundation"),
        ]
    )
)
#endif

let package = Package(
    name: "Pebble",
    platforms: [.macOS(.v14)],
    targets: targets
)
