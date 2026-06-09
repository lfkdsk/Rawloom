// swift-tools-version: 5.9
import PackageDescription

// Rawloom — algorithm core.
//
// The capture + UI layers live in the iOS app target (assembled via project.yml / XcodeGen),
// because they depend on AVFoundation raw capture and UIKit which are iOS-only. Everything in
// this package is the *portable* compute pipeline: it builds and unit-tests on macOS too, so the
// alignment / merge / finishing math can be exercised on synthetic mosaics in CI without a phone.
let package = Package(
    name: "Rawloom",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RawloomCore", targets: ["RawloomCore"]),
    ],
    targets: [
        .target(
            name: "RawloomCore",
            resources: [
                // We ship the .metal files as *source* (copied verbatim) and compile them at
                // runtime with MTLDevice.makeLibrary(source:). This avoids a build-time dependency
                // on the `metal` compiler (so the package builds under Command Line Tools alone and
                // in CI), and is a perfectly valid on-device strategy — the one-time runtime compile
                // is cached by Metal. See MetalContext.loadLibrary().
                .copy("Shaders"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
        .testTarget(
            name: "RawloomCoreTests",
            dependencies: ["RawloomCore"]
        ),
    ]
)
