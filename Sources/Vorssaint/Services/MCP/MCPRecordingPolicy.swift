// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPRecordingPolicy {
    static let maxBytes: Int64 = 32 * 1024 * 1024
    static let chunkBytes = 6 * 1024
    static let lifetime: TimeInterval = 120
    static func owned(_ requested: String?, owner: UUID?) -> Bool {
        guard let requested, let id = UUID(uuidString: requested), let owner else { return false }
        return id == owner
    }

    static func pauseAction(_ value: String?) -> Bool? {
        switch value {
        case "pause": return true
        case "resume": return false
        default: return nil
        }
    }

    static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "gif": return "image/gif"
        default: return nil
        }
    }

    static func validSize(_ size: Int64) -> Bool { size > 0 && size <= maxBytes }
    static func validOffset(_ offset: Int, next: Int, size: Int64) -> Bool {
        offset >= 0 && offset == next && Int64(offset) < size
    }
}
