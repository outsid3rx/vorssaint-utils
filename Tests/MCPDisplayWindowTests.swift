// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPDisplayWindowTests {
    static func run(_ suite: TestSuite) {
        suite.expect(MCPDisplayWindowPolicy.displayID("123") == 123, "valid live display id")
        for invalid in ["", "0", "-1", "1.0", "4294967296", "１２"] {
            suite.expect(MCPDisplayWindowPolicy.displayID(invalid) == nil, "invalid display id rejected: \(invalid)")
        }
        suite.expect(MCPDisplayWindowPolicy.processID("42") == 42, "valid process id")
        suite.expect(MCPDisplayWindowPolicy.processID("2147483648") == nil, "out-of-range process id rejected")
        for value in [0.0, 0.5, 1.0] {
            suite.expect(MCPDisplayWindowPolicy.brightness(value) == value, "valid brightness \(value)")
        }
        for value in [-0.1, 1.1, Double.nan, Double.infinity] {
            suite.expect(MCPDisplayWindowPolicy.brightness(value) == nil, "invalid brightness rejected")
        }
        suite.expect(MCPDisplayWindowPolicy.canSetBrightness(active: true, hasRoute: true, pending: false),
                     "active display with brightness route accepts writes")
        suite.expect(!MCPDisplayWindowPolicy.canSetBrightness(active: false, hasRoute: true, pending: false),
                     "inactive display rejects writes")
        suite.expect(!MCPDisplayWindowPolicy.canSetBrightness(active: true, hasRoute: false, pending: false),
                     "display without route rejects writes")
        suite.expect(!MCPDisplayWindowPolicy.canSetBrightness(active: true, hasRoute: true, pending: true),
                     "display transitioning power rejects writes")
        suite.expect(MCPDisplayWindowPolicy.displayPageOffset(nil, total: 4) == 0,
                     "display pagination defaults to the first page")
        suite.expect(MCPDisplayWindowPolicy.displayPageOffset(4, total: 4) == 4,
                     "display pagination can address the end of the snapshot")
        suite.expect(MCPDisplayWindowPolicy.displayPageOffset(-1, total: 4) == nil,
                     "negative display page rejected")
        suite.expect(MCPDisplayWindowPolicy.displayPageOffset(5, total: 4) == nil,
                     "display page past the snapshot rejected")
        suite.expect(MCPDisplayWindowPolicy.displayPageOffset(1_000_001, total: 1_000_001) == nil,
                     "excessive display page rejected")
        suite.expect(MCPDisplayWindowPolicy.action("leftHalf") == "leftHalf", "layout action accepted")
        suite.expect(MCPDisplayWindowPolicy.action("nextDisplay") == "nextDisplay", "display move accepted")
        suite.expect(MCPDisplayWindowPolicy.action("fullScreen") == nil, "toggle is not exposed")
        suite.expect(MCPDisplayWindowPolicy.action("unknown") == nil, "unknown layout action rejected")
        suite.expect(MCPDisplayWindowPolicy.windowActions == Set(WindowLayoutAction.allCases.filter { $0 != .fullScreen }.map(\.rawValue)),
                     "exposed layout actions match the non-toggle app actions")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: false, expectedPID: 42, frontmostPID: 42,
            isIgnored: false) == .sessionInactive,
            "locked session blocks window commands")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: true, expectedPID: 42, frontmostPID: 42,
            isIgnored: false, accessEnabled: false) == .accessDisabled,
            "revoking MCP access blocks delayed window work")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: true, expectedPID: 42, frontmostPID: 43,
            isIgnored: false) == .activeAppChanged,
            "switching frontmost app blocks the command")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: true, expectedPID: 42, frontmostPID: 42,
            isIgnored: WindowLayoutIgnoredApps.matches(bundleID: "com.example.app", executablePath: nil,
                                                       apps: ["com.example.app"])) == .ignoredApp,
            "ignored bundle id blocks window commands")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: true, expectedPID: 42, frontmostPID: 42,
            isIgnored: WindowLayoutIgnoredApps.matches(bundleID: "com.example.app", executablePath: "/usr/local/bin/demo",
                                                       apps: ["/usr/local/bin/demo"])) == .ignoredApp,
            "ignored executable path blocks window commands")
        suite.expect(MCPDisplayWindowPolicy.windowBlock(sessionActive: true, expectedPID: 42, frontmostPID: 42,
            isIgnored: false) == nil,
            "active session and allowed frontmost app proceed")
    }
}
