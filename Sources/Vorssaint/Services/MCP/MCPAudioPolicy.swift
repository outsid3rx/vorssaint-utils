// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Validate before passing a value to the mixer's sanitizers, which otherwise
/// silently clamp invalid input into a different requested level.
enum MCPAudioPolicy {
    static func validSystemVolume(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    static func validAppVolume(_ value: Double) -> Bool {
        value.isFinite && (0...2).contains(value)
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024
    }
}
