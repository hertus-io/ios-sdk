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
        // Opted into separately, so a host app that wants no identification
        // engine links none. See Sources/HertusGuardS1.
        .library(name: "HertusGuardS1", targets: ["HertusGuardS1"]),
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
        // The adapter onto the identification engine, and the only target that
        // imports it.
        //
        // The vendor dependency is not declared yet, so `canImport` is false
        // and this compiles to an empty module: the package resolves and builds
        // on a host with no Apple SDK, and `HertusGuardS1.enable()` answers
        // false. Adding the dependency is a Mac-side change, because the engine
        // ships as an Apple binary and cannot be compiled anywhere else.
        .target(
            name: "HertusGuardS1",
            dependencies: ["HertusCore"],
            path: "Sources/HertusGuardS1"
        ),
        .executableTarget(
            name: "HertusSample",
            dependencies: ["Hertus"],
            path: "Sources/HertusSample"
        ),
        .testTarget(
            name: "HertusCoreTests",
            dependencies: ["HertusCore", "HertusGuardS1"],
            path: "Tests/HertusCoreTests"
        ),
    ]
)
