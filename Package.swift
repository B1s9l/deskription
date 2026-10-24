// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 B1s9l
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskriptionsLab",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DeskriptionsLab", targets: ["DeskriptionsLab"]),
        .executable(name: "deskriptions-bridge", targets: ["DeskriptionsBridge"]),
        .executable(name: "deskriptions-diagnose", targets: ["DeskriptionsDiagnose"]),
        .library(name: "DeskriptionsCore", targets: ["DeskriptionsCore"])
    ],
    targets: [
        .target(name: "DeskriptionsCore"),
        .executableTarget(name: "DeskriptionsLab", dependencies: ["DeskriptionsCore"]),
        .executableTarget(name: "DeskriptionsBridge", dependencies: ["DeskriptionsCore"]),
        .executableTarget(name: "DeskriptionsDiagnose", dependencies: ["DeskriptionsCore"]),
        .testTarget(name: "DeskriptionsCoreTests", dependencies: ["DeskriptionsCore"])
    ],
    swiftLanguageModes: [.v5]
)

