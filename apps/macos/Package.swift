// swift-tools-version:6.0
import PackageDescription
import Foundation

// The Rust static library is produced by scripts/build-app.sh
// (`cargo build --release -p corax-uniffi`). Its directory can be overridden so
// the same package can be built against a different target triple.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libraryDirectory = ProcessInfo.processInfo.environment["CORAX_LIB_DIR"]
    ?? packageDirectory
        .appendingPathComponent("../../src-tauri/target/release")
        .standardizedFileURL
        .path

// Native libraries the Rust static library needs. Exact list from
// `cargo rustc -p corax-uniffi --release --lib -- --print native-static-libs`:
//   -framework SystemConfiguration -lobjc -framework IOKit
//   -framework CoreFoundation -framework Security -liconv
// (`-lSystem -lc -lm` come from the toolchain; `AppKit`/`Foundation` are added
// because our Swift sources import them.)
let rustNativeFrameworks: [LinkerSetting] = [
    .linkedFramework("SystemConfiguration"),
    .linkedFramework("IOKit"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("Security"),
    .linkedLibrary("objc"),
    .linkedLibrary("iconv"),
]

let package = Package(
    name: "Corax",
    platforms: [.macOS("27.0")],
    // M3.2: Sparkle 2 (MIT) für Updates. Fest angeheftet: die App ist ad-hoc
    // signiert, die Updates trägt die EdDSA-Signatur (siehe Updater.swift).
    // Nur das App-Target bekommt Sparkle; CoraxKit bleibt AppKit-frei.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Generated C module: CoraxFFI.h + module.modulemap from uniffi-bindgen.
        .target(
            name: "CoraxFFI",
            path: "Generated/ffi",
            linkerSettings: [
                .unsafeFlags(["-L", libraryDirectory]),
                .linkedLibrary("corax_uniffi"),
            ] + rustNativeFrameworks
        ),
        // Generated Swift wrappers. Swift 5 language mode: the generated code
        // predates strict concurrency checking and is not the thing we test here.
        .target(
            name: "CoraxBindings",
            dependencies: ["CoraxFFI"],
            path: "Generated/swift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Plattformneutraler Kern: Core, State und Support ohne AppKit,
        // SwiftUI oder WebKit (`scripts/check-coraxkit.sh` prüft das).
        .target(
            name: "CoraxKit",
            dependencies: ["CoraxBindings", "CoraxFFI"],
            path: "Sources/CoraxKit"
        ),
        // M3.3: Siri und Kurzbefehle. Eigenes Modul, damit der Intent-Code ohne
        // AppKit auskommt und sich später unverändert in die eigenständige App tragen
        // lässt; das App-Target hängt nur davon ab.
        .target(
            name: "CoraxIntents",
            dependencies: ["CoraxKit"],
            path: "Sources/CoraxIntents",
            linkerSettings: [
                .linkedFramework("AppIntents"),
            ]
        ),
        // Nur UI: AppKit, SwiftUI, WebKit und die Mac-Seite von `PlatformServices`.
        .executableTarget(
            name: "Corax",
            dependencies: [
                "CoraxKit", "CoraxBindings", "CoraxFFI", "CoraxIntents",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Corax",
            // Sparkle.framework liegt im Bundle unter Contents/Frameworks.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Argument names of the IPC wrappers against the contract in
        // `src/ipc/types.ts` (run with `swift test`).
        .testTarget(
            name: "CoraxTests",
            dependencies: ["Corax", "CoraxIntents"],
            path: "Tests/CoraxTests"
        ),
    ]
)
