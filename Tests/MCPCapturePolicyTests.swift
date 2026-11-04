// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPCapturePolicyTests {
    static func run(_ suite: TestSuite) {
        for mode in ["screenshot", "text", "qr"] {
            suite.expect(MCPCapturePolicy.canStart(mode: mode), "capture supports explicitly listed mode")
        }
        suite.expect(!MCPCapturePolicy.canStart(mode: "recording"), "capture does not enter recording")
        suite.expect(!MCPCapturePolicy.canStart(mode: ""), "capture rejects empty mode")
        suite.expect(MCPCapturePolicy.validOffset(0, size: 0, nextOffset: 0), "empty result can finish")
        suite.expect(MCPCapturePolicy.validOffset(6144, size: 7000, nextOffset: 6144), "next chunk offset is accepted")
        suite.expect(!MCPCapturePolicy.validOffset(0, size: 7000, nextOffset: 6144), "already-read chunk cannot be replayed")
        suite.expect(!MCPCapturePolicy.validOffset(6145, size: 7000, nextOffset: 6144), "read cannot skip data")
        suite.expect(!MCPCapturePolicy.validOffset(-1, size: 1, nextOffset: -1), "negative offset is invalid")
        suite.expect(!MCPCapturePolicy.validOffset(2, size: 1, nextOffset: 2), "offset past end is invalid")
        suite.expect(!MCPCapturePolicy.validOffset(0, size: MCPCapturePolicy.maxBytes + 1, nextOffset: 0), "oversize result is invalid")
        suite.expect(MCPCapturePolicy.canRead(approved: true, ready: true, accessEnabled: true, screenPermission: true), "approved ready capture can be read")
        suite.expect(!MCPCapturePolicy.canRead(approved: false, ready: true, accessEnabled: true, screenPermission: true), "capture cannot be read before approval")
        suite.expect(!MCPCapturePolicy.canRead(approved: true, ready: false, accessEnabled: true, screenPermission: true), "capture cannot be read before processing")
        suite.expect(!MCPCapturePolicy.canRead(approved: true, ready: true, accessEnabled: false, screenPermission: true), "revoking MCP content blocks reading")
        suite.expect(!MCPCapturePolicy.canRead(approved: true, ready: true, accessEnabled: true, screenPermission: false), "revoking screen permission blocks reading")

        let now = Date(timeIntervalSince1970: 1_000)
        let png = Data([0x89, 0x50, 0x4e, 0x47]) + Data(repeating: 0x7a, count: 7_000)
        var store = MCPCaptureStore()
        suite.expect(!store.blocksNewCapture, "empty store permits a new selection")
        store.begin(id: "one", mode: "screenshot")
        suite.expect(store.blocksNewCapture, "selection cannot be silently replaced")
        store.finish(id: "one", data: png, mime: "image/png", now: now)
        if case .failure(.notReady) = store.read(id: "one", offset: 0, now: now) {} else {
            suite.expect(false, "unapproved screenshot cannot be read")
        }
        suite.expect(store.awaitApproval(id: "one") && store.approve(id: "one"), "selected capture is approved")
        suite.expect(store.blocksNewCapture, "processing cannot be silently replaced")
        store.finish(id: "one", data: png, mime: "image/png", now: now)
        suite.expect(store.blocksNewCapture, "approved unread capture blocks a new selection")
        if case .failure(.invalidOffset) = store.read(id: "one", offset: 1, now: now) {} else {
            suite.expect(false, "first read cannot skip bytes")
        }
        if case .success(let first) = store.read(id: "one", offset: 0, now: now) {
            suite.expect(first.data == png.prefix(MCPCapturePolicy.chunkBytes), "first PNG chunk preserves bytes")
            suite.expect(first.mime == "image/png" && first.total == png.count && first.nextOffset == MCPCapturePolicy.chunkBytes,
                         "first PNG chunk carries size and next offset")
        } else { suite.expect(false, "first approved PNG chunk is readable") }
        if case .failure(.invalidOffset) = store.read(id: "one", offset: 0, now: now) {} else {
            suite.expect(false, "PNG chunk cannot be replayed")
        }
        if case .success(let last) = store.read(id: "one", offset: MCPCapturePolicy.chunkBytes, now: now) {
            suite.expect(last.data == png.dropFirst(MCPCapturePolicy.chunkBytes) && last.nextOffset == nil,
                         "last PNG chunk is complete")
        } else { suite.expect(false, "last PNG chunk is readable") }
        suite.expect(store.operation == nil, "last chunk consumes the approved capture")
        suite.expect(!store.blocksNewCapture, "consumed capture permits a new selection")
        if case .failure(.notFound) = store.read(id: "one", offset: 0, now: now) {} else {
            suite.expect(false, "consumed capture cannot be read twice")
        }

        store.begin(id: "text", mode: "text")
        _ = store.awaitApproval(id: "text"); _ = store.approve(id: "text")
        store.finish(id: "text", data: Data("Тест".utf8), mime: "text/plain; charset=utf-8", now: now)
        if case .success(let text) = store.read(id: "text", offset: 0, now: now) {
            suite.expect(String(data: text.data, encoding: .utf8) == "Тест", "UTF-8 result round-trips")
        } else { suite.expect(false, "approved text is readable") }

        store.begin(id: "deny", mode: "qr")
        _ = store.awaitApproval(id: "deny")
        store.terminal(id: "deny", state: .denied, now: now)
        suite.expect(!store.blocksNewCapture, "denied capture does not block a new selection")
        store.finish(id: "deny", data: Data("secret".utf8), mime: "text/plain", now: now)
        if case .failure(.notReady) = store.read(id: "deny", offset: 0, now: now) {} else {
            suite.expect(false, "denied capture cannot become readable from a late callback")
        }
        store.begin(id: "old", mode: "text")
        _ = store.awaitApproval(id: "old"); _ = store.approve(id: "old")
        store.begin(id: "new", mode: "text")
        store.finish(id: "old", data: Data("old".utf8), mime: "text/plain", now: now)
        suite.expect(store.operation?.id == "new" && store.operation?.state == .selecting,
                     "old recognition callback cannot overwrite a new request")
        store.discard()
        store.finish(id: "new", data: Data("late".utf8), mime: "text/plain", now: now)
        suite.expect(store.operation == nil, "discard or revoked access rejects a late callback")

        store.begin(id: "expire", mode: "text")
        _ = store.awaitApproval(id: "expire"); _ = store.approve(id: "expire")
        store.finish(id: "expire", data: Data("short".utf8), mime: "text/plain", now: now)
        if case .failure(.notFound) = store.read(id: "expire", offset: 0,
                                                now: now.addingTimeInterval(MCPCapturePolicy.lifetime)) {} else {
            suite.expect(false, "capture expires before it can be read")
        }
        suite.expect(!store.blocksNewCapture, "expired capture does not block a new selection")
        store.begin(id: "large", mode: "screenshot")
        _ = store.awaitApproval(id: "large"); _ = store.approve(id: "large")
        store.finish(id: "large", data: Data(repeating: 1, count: MCPCapturePolicy.maxBytes + 1),
                     mime: "image/png", now: now)
        suite.expect(store.operation?.state == .failed && store.operation?.error == "result_too_large",
                     "oversized capture is rejected without retaining its bytes")
        suite.expect(store.operation?.data == nil, "oversized capture data is not retained")
    }
}
