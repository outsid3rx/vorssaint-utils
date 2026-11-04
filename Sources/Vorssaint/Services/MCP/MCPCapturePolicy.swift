// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPCapturePolicy {
    static let maxBytes = 8 * 1024 * 1024
    static let chunkBytes = 6 * 1024
    static let lifetime: TimeInterval = 120

    static func validOffset(_ offset: Int, size: Int, nextOffset: Int) -> Bool {
        offset == nextOffset && offset >= 0 && offset <= size && size >= 0 && size <= maxBytes
    }

    static func canStart(mode: String) -> Bool {
        ["screenshot", "text", "qr"].contains(mode)
    }

    static func canRead(approved: Bool, ready: Bool, accessEnabled: Bool, screenPermission: Bool) -> Bool {
        approved && ready && accessEnabled && screenPermission
    }
}

/// Stores only a single explicitly approved result. This type has no UI or
/// screen access, so its lifecycle can be tested with synthetic data.
struct MCPCaptureStore {
    enum State: String { case selecting, awaitingApproval, processing, ready, denied, cancelled, failed }
    enum ReadError: Error, Equatable { case notFound, notReady, invalidOffset }
    struct Operation {
        let id: String
        let mode: String
        var state: State
        var error: String?
        var data: Data?
        var mime: String?
        var expires: Date?
        var nextOffset = 0
        var approved = false
    }
    struct Chunk {
        let data: Data
        let mime: String
        let offset: Int
        let total: Int
        let nextOffset: Int?
    }
    private(set) var operation: Operation?

    /// An approved but unread result is retained until read, discarded or
    /// expired; a new capture must never silently overwrite it.
    var blocksNewCapture: Bool {
        guard let state = operation?.state else { return false }
        switch state {
        case .selecting, .awaitingApproval, .processing, .ready: return true
        case .denied, .cancelled, .failed: return false
        }
    }

    mutating func begin(id: String, mode: String) {
        operation = Operation(id: id, mode: mode, state: .selecting)
    }

    mutating func awaitApproval(id: String) -> Bool {
        guard operation?.id == id, operation?.state == .selecting else { return false }
        operation?.state = .awaitingApproval
        return true
    }

    mutating func approve(id: String) -> Bool {
        guard operation?.id == id, operation?.state == .awaitingApproval else { return false }
        operation?.approved = true
        operation?.state = .processing
        return true
    }

    mutating func finish(id: String, data: Data, mime: String, now: Date) {
        guard operation?.id == id, operation?.state == .processing, operation?.approved == true else { return }
        guard data.count <= MCPCapturePolicy.maxBytes else {
            terminal(id: id, state: .failed, error: "result_too_large", now: now)
            return
        }
        operation?.data = data
        operation?.mime = mime
        operation?.expires = now.addingTimeInterval(MCPCapturePolicy.lifetime)
        operation?.state = .ready
    }

    mutating func terminal(id: String, state: State, error: String? = nil, now: Date) {
        guard operation?.id == id, [.denied, .cancelled, .failed].contains(state) else { return }
        operation?.state = state
        operation?.error = error
        operation?.data = nil
        operation?.approved = false
        operation?.expires = now.addingTimeInterval(MCPCapturePolicy.lifetime)
    }

    @discardableResult
    mutating func expire(now: Date) -> Bool {
        guard let expiry = operation?.expires, expiry <= now else { return false }
        operation = nil
        return true
    }

    mutating func discard() { operation = nil }

    mutating func read(id: String, offset: Int, now: Date) -> Result<Chunk, ReadError> {
        expire(now: now)
        guard let current = operation, current.id == id else { return .failure(.notFound) }
        guard MCPCapturePolicy.canRead(approved: current.approved, ready: current.state == .ready,
                                       accessEnabled: true, screenPermission: true),
              let bytes = current.data, let mime = current.mime else { return .failure(.notReady) }
        guard MCPCapturePolicy.validOffset(offset, size: bytes.count, nextOffset: current.nextOffset) else {
            return .failure(.invalidOffset)
        }
        let end = min(offset + MCPCapturePolicy.chunkBytes, bytes.count)
        let chunk = Chunk(data: bytes.subdata(in: offset..<end), mime: mime, offset: offset,
                          total: bytes.count, nextOffset: end == bytes.count ? nil : end)
        if chunk.nextOffset == nil { operation = nil } else { operation?.nextOffset = end }
        return .success(chunk)
    }
}
