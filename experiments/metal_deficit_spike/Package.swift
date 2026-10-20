// swift-tools-version:5.9
import PackageDescription

// Standalone spike (see RESULTS.md). Depends on BeehiveMac by path for
// BeehiveKit — Audio/BandEnvelopes/DSP/Tempo are reused, not reimplemented.
// Nothing under BeehiveMac/, beecore/ or beehive/ is modified by this package.
let package = Package(
    name: "MetalDeficitSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BeehiveMac"),
    ],
    targets: [
        .executableTarget(
            name: "DeficitSpike",
            dependencies: [.product(name: "BeehiveKit", package: "BeehiveMac")]
        ),
    ]
)
