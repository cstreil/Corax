// swift-tools-version:6.0
import PackageDescription
import Foundation

// The Rust static library is produced by scripts/build-app.sh
// (`cargo build --release -p rabe-uniffi`). Its directory can be overridden so
// the same package can be built against a different target triple.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libraryDirectory = ProcessInfo.processInfo.environment["RABE_LIB_DIR"]
    ?? packageDirectory
        .appendingPathComponent("../../src-tauri/target/release")
        .standardizedFileURL
        .path

// Native libraries the Rust static library needs. Exact list from
// `cargo rustc -p rabe-uniffi --release --lib -- --print native-static-libs`:
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
    name: "Rabe",
    platforms: [.macOS("27.0")],
    targets: [
        // Generated C module: RabeFFI.h + module.modulemap from uniffi-bindgen.
        .target(
            name: "RabeFFI",
            path: "Generated/ffi",
            linkerSettings: [
                .unsafeFlags(["-L", libraryDirectory]),
                .linkedLibrary("rabe_uniffi"),
            ] + rustNativeFrameworks
        ),
        // Generated Swift wrappers. Swift 5 language mode: the generated code
        // predates strict concurrency checking and is not the thing we test here.
        .target(
            name: "RabeBindings",
            dependencies: ["RabeFFI"],
            path: "Generated/swift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Plattformneutraler Kern: Core, State und Support ohne AppKit,
        // SwiftUI oder WebKit (`scripts/check-rabekit.sh` prüft das).
        .target(
            name: "RabeKit",
            dependencies: ["RabeBindings", "RabeFFI"],
            path: "Sources/RabeKit"
        ),
        // Nur UI: AppKit, SwiftUI, WebKit und die Mac-Seite von `PlatformServices`.
        .executableTarget(
            name: "Rabe",
            dependencies: ["RabeKit", "RabeBindings", "RabeFFI"],
            path: "Sources/Rabe"
        ),
        // Argument names of the IPC wrappers against the contract in
        // `src/ipc/types.ts` (run with `swift test`).
        .testTarget(
            name: "RabeTests",
            dependencies: ["Rabe"],
            path: "Tests/RabeTests"
        ),
    ]
)
