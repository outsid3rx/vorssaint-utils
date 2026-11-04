// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

extension MCPKeepAwakeAdapter {
    /// Call and execute on the main thread, like FeatureRuntime and its services.
    static func live() -> MCPKeepAwakeAdapter {
        precondition(Thread.isMainThread)
        return MCPKeepAwakeAdapter(
            allowedDurations: Defaults.allowedDurations,
            available: { AppFeature.keepAwake.isAvailable },
            snapshot: {
                let manager = KeepAwakeManager.shared
                return MCPKeepAwakeState(
                    available: AppFeature.keepAwake.isAvailable,
                    active: manager.isActive,
                    endDate: manager.endDate,
                    trigger: manager.sessionTrigger.map { $0 == .manual ? "manual" : "automation" })
            },
            start: { KeepAwakeManager.shared.activate(minutes: $0) },
            stop: { KeepAwakeManager.shared.stopManualSession() }
        )
    }
}
