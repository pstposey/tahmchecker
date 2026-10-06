// swift-tools-version:6.0
//
// RedlineCore — platform-independent telemetry engine for Redline.
//
// Everything in this package is pure Swift + Foundation (+ Observation) so it
// builds and tests on Linux and macOS without a device or CoreBluetooth.
// Platform I/O (CoreBluetooth, SwiftUI) lives in the app target and talks to
// this package through the `OBDTransport` protocol.

import PackageDescription

let package = Package(
    name: "RedlineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RedlineCore", targets: ["RedlineCore"]),
    ],
    targets: [
        .target(name: "RedlineCore"),
        .testTarget(name: "RedlineCoreTests", dependencies: ["RedlineCore"]),
    ]
)
