// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import PackageDescription

let package = Package(
    name: "VorssaintMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.10.0"),
        // Keep the dependency graph compatible with CI's Swift 6.0 toolchain.
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.4"),
        .package(url: "https://github.com/mattt/eventsource.git", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(name: "VorssaintMCP", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "EventSource", package: "eventsource")
        ])
    ]
)
