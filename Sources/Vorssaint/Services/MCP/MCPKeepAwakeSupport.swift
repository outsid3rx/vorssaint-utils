// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPKeepAwakeCommand {
    case status
    case start(minutes: Int)
    case stop
}

struct MCPKeepAwakeState: Equatable {
    let available: Bool
    let active: Bool
    let endDate: Date?
    let trigger: String?
}

enum MCPKeepAwakeError: Error, Equatable {
    case unavailable
    case invalidDuration
    case activationFailed
}

/// The closures are supplied by the app on the main thread. Keeping the
/// policy here independent of the service lets tests verify rejected commands
/// never change its state.
struct MCPKeepAwakeAdapter {
    let allowedDurations: [Int]
    let available: () -> Bool
    let snapshot: () -> MCPKeepAwakeState
    let start: (Int) -> Void
    let stop: () -> Void

    func execute(_ command: MCPKeepAwakeCommand) -> Result<MCPKeepAwakeState, MCPKeepAwakeError> {
        if case .start(let minutes) = command, !allowedDurations.contains(minutes) {
            return .failure(.invalidDuration)
        }
        guard available() else {
            if case .status = command {
                return .success(MCPKeepAwakeState(available: false, active: false, endDate: nil, trigger: nil))
            }
            return .failure(.unavailable)
        }
        switch command {
        case .status:
            break
        case .start(let minutes):
            start(minutes)
            guard snapshot().active else { return .failure(.activationFailed) }
        case .stop:
            stop()
        }
        return .success(snapshot())
    }
}
