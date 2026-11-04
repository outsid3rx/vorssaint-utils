// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPKeepAwakeTests {
    static func run(_ suite: TestSuite) {
        suite.expect(!SettingsBackupSupport.exportKeys().contains(DefaultsKey.mcpEnabled),
                     "local MCP authorization is not exported to another Mac")
        for key in [DefaultsKey.mcpAudioEnabled, DefaultsKey.mcpDisplayEnabled, DefaultsKey.mcpWindowEnabled] {
            suite.expect(!SettingsBackupSupport.exportKeys().contains(key), "MCP category authorization is local")
            suite.expect(Defaults.registeredDefaults[key] as? Bool == false, "MCP category is disabled by default")
        }
        var available = true
        var active = false
        var starts = [Int]()
        var stops = 0
        let adapter = MCPKeepAwakeAdapter(
            allowedDurations: Defaults.allowedDurations,
            available: { available },
            snapshot: { MCPKeepAwakeState(available: available, active: active, endDate: nil,
                                           trigger: active ? "manual" : nil) },
            start: { minutes in starts.append(minutes); active = true },
            stop: { stops += 1; active = false }
        )

        suite.expect(adapter.execute(.start(minutes: 17)) == .failure(.invalidDuration),
                     "unsupported duration is rejected instead of becoming indefinite")
        suite.expect(adapter.execute(.start(minutes: -1)) == .failure(.invalidDuration),
                     "negative duration is rejected")
        suite.expect(starts.isEmpty, "invalid input has no effect")
        for minutes in Defaults.allowedDurations {
            let result = adapter.execute(.start(minutes: minutes))
            suite.expect(result == .success(MCPKeepAwakeState(available: true, active: true,
                                                              endDate: nil, trigger: "manual")),
                         "supported duration \(minutes) starts a session")
        }
        suite.expect(starts == Defaults.allowedDurations, "all requested durations are forwarded")
        _ = adapter.execute(.stop)
        suite.expect(!active && stops == 1, "stop ends the session")
        available = false
        suite.expect(adapter.execute(.status) == .success(MCPKeepAwakeState(
            available: false, active: false, endDate: nil, trigger: nil)), "unavailable status is readable")
        suite.expect(adapter.execute(.start(minutes: 15)) == .failure(.unavailable), "unavailable start fails")
        suite.expect(adapter.execute(.stop) == .failure(.unavailable), "unavailable stop fails")
        suite.expect(starts == Defaults.allowedDurations && stops == 1, "unavailable commands have no effect")

        let failing = MCPKeepAwakeAdapter(allowedDurations: Defaults.allowedDurations,
            available: { true },
            snapshot: { MCPKeepAwakeState(available: true, active: false, endDate: nil, trigger: nil) },
            start: { _ in }, stop: {})
        suite.expect(failing.execute(.start(minutes: 15)) == .failure(.activationFailed),
                     "a failed activation is reported")
    }
}
