// swift-tools-version: 5.9

import PackageDescription

// The SDK is split in two on purpose.
//
// `Hertus` is the product a host app depends on. `HertusCore` underneath it is
// platform independent: Foundation only, no UIKit, no AppTrackingTransparency,
// nothing that needs a device. Everything with a decision in it lives there,
// which is what lets the event model, the validation rules, the state machine
// and the retry schedule be tested on any machine with a Swift toolchain rather
// than only on a Mac with a simulator.
//
// The platform layer above it stays thin enough to read in one sitting, because
// it is the part that cannot be covered by these tests.
let package = Package(
    name: "Hertus",
    platforms: [
        // Matches the Android minSdk decision in spirit: low enough to cover
        // what customers actually ship to, high enough that the SDK is not
        // shaped by a version nobody runs.
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "Hertus", targets: ["Hertus"]),
        // Runs on any host with a Swift toolchain, which is the point: it
        // exercises the parts of the SDK that have no device in them, on a
        // machine that has no simulator.
        .executable(name: "hertus-sample", targets: ["HertusSample"]),
    ],
    targets: [
        .target(
            name: "HertusCore",
            path: "Sources/HertusCore"
        ),
        .target(
            name: "Hertus",
            dependencies: ["HertusCore"],
            path: "Sources/Hertus"
        ),
        .executableTarget(
            name: "HertusSample",
            dependencies: ["Hertus"],
            path: "Sources/HertusSample"
        ),
        .testTarget(
            name: "HertusCoreTests",
            dependencies: ["HertusCore"],
            path: "Tests/HertusCoreTests"
        ),
    ]
)
