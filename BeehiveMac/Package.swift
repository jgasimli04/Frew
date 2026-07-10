// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BeehiveMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BeehiveKit", targets: ["BeehiveKit"]),
        .executable(name: "BeehiveApp", targets: ["BeehiveApp"]),
        .executable(name: "beehive-cli", targets: ["beehive-cli"]),
    ],
    targets: [
        // The bee-ffi C ABI (blueprint §4c: Swift is the .bee consumer; the
        // codec lives in the Rust core). Header-only shim; the static library
        // is built by `cargo build --release` in ../beecore and copied to
        // Libraries/libbee_ffi.a — re-copy after changing the Rust core.
        .target(
            name: "CBee",
            linkerSettings: [
                .unsafeFlags(["-L\(Context.packageDirectory)/Libraries"]),
                .linkedLibrary("bee_ffi"),
            ]
        ),
        .target(name: "BeehiveKit", dependencies: ["CBee"]),
        .executableTarget(name: "BeehiveApp", dependencies: ["BeehiveKit"]),
        .executableTarget(name: "beehive-cli", dependencies: ["BeehiveKit"]),
        // NOTE: Tests/BeehiveKitTests (XCTest) runs under Xcode. Command Line
        // Tools has no XCTest, so the same checks also run via `beehive-cli --selftest`.
    ]
)
