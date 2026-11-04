// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Restrict MCP to explicit layout actions; fullScreen is a toggle and is not
/// exposed. IDs refer to live objects, not persistent identities.
enum MCPDisplayWindowPolicy {
    enum WindowBlock: Equatable { case accessDisabled, sessionInactive, activeAppChanged, ignoredApp }
    static let windowActions: Set<String> = [
        "leftHalf", "rightHalf", "topHalf", "bottomHalf", "centerHalf",
        "leftThird", "centerThird", "rightThird", "leftTwoThirds", "rightTwoThirds", "centerTwoThirds",
        "topThird", "middleThird", "bottomThird", "topTwoThirds", "bottomTwoThirds",
        "topQuarter", "upperMiddleQuarter", "lowerMiddleQuarter", "bottomQuarter",
        "leftQuarter", "leftMiddleQuarter", "rightMiddleQuarter", "rightQuarter",
        "topLeftSixth", "topCenterSixth", "topRightSixth", "bottomLeftSixth", "bottomCenterSixth", "bottomRightSixth",
        "topLeft", "topRight", "bottomLeft", "bottomRight", "maximize", "marginMaximize", "center",
        "previousDisplay", "nextDisplay", "restore"
    ]

    static func displayID(_ raw: String?) -> UInt32? {
        guard let raw, !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt32(raw), value > 0 else { return nil }
        return value
    }

    static func processID(_ raw: String?) -> Int32? {
        guard let raw, !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int32(raw), value > 0 else { return nil }
        return value
    }

    static func brightness(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    static func canSetBrightness(active: Bool, hasRoute: Bool, pending: Bool) -> Bool {
        active && hasRoute && !pending
    }

    static func displayPageOffset(_ value: Int?, total: Int) -> Int? {
        let offset = value ?? 0
        guard total >= 0, (0...1_000_000).contains(offset), offset <= total else { return nil }
        return offset
    }

    static func windowBlock(sessionActive: Bool, expectedPID: Int32, frontmostPID: Int32?,
                            isIgnored: Bool, accessEnabled: Bool = true) -> WindowBlock? {
        guard accessEnabled else { return .accessDisabled }
        guard sessionActive else { return .sessionInactive }
        guard frontmostPID == expectedPID else { return .activeAppChanged }
        if isIgnored { return .ignoredApp }
        return nil
    }

    static func action(_ value: String?) -> String? {
        guard let value, windowActions.contains(value) else { return nil }
        return value
    }
}
