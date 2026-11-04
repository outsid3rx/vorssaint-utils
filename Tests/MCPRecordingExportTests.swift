// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation

enum MCPRecordingExportTests {
    final class Fixture {
        struct MCPIPCResponse {
            let ok: Bool
            var error: String? = nil
            var payload: String? = nil
        }
        var ownerID: UUID? = UUID()
        var allowed = true
        var exportFD: Int32 = -1
        var exportSize: Int64 = 0
        var exportModificationSeconds: Int = 0
        var exportModificationNanos: Int = 0
        var exportMIME = "application/octet-stream"
        var exportState = "not_exported"
        var exportNextOffset = 0
        var exportExpiry: Date?
        var approval: NSAlert?
        func contentAllowed() -> Bool { allowed }
        func installTimer() {}
        deinit { if exportFD >= 0 { close(exportFD) } }
    }

    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("output.mp4")
            let original = Data((0..<7000).map { UInt8($0 % 251) })
            try original.write(to: url)
            let fixture = Fixture()
            let id = fixture.ownerID!
            fixture.recordingDidExport(id: UUID(), url: url)
            suite.expect(fixture.exportFD == -1, "other recording cannot register export")
            fixture.recordingDidExport(id: id, url: url)
            suite.expect(fixture.exportState == "available_for_approval" && fixture.exportExpiry != nil, "own export awaits approval and has expiry")
            suite.expect(fixture.readExport(offset: 0).error == "export_not_ready", "unapproved file cannot be read")
            fixture.exportState = "ready" // Simulate the approval dialog's positive result.
            suite.expect(fixture.readExport(offset: 1).error == "invalid_offset", "out of order offset is rejected")
            let first = fixture.readExport(offset: 0)
            let firstJSON = (try? JSONSerialization.jsonObject(with: Data((first.payload ?? "").utf8))) as? [String: Any]
            suite.expect(first.ok && firstJSON?["next_offset"] as? Int == 6144, "first chunk has expected next offset")
            suite.expect(fixture.readExport(offset: 0).error == "invalid_offset", "previous chunk is one shot")
            let last = fixture.readExport(offset: 6144)
            let lastJSON = (try? JSONSerialization.jsonObject(with: Data((last.payload ?? "").utf8))) as? [String: Any]
            let firstBytes = Data(base64Encoded: firstJSON?["data_base64"] as? String ?? "") ?? Data()
            let lastBytes = Data(base64Encoded: lastJSON?["data_base64"] as? String ?? "") ?? Data()
            suite.expect(firstBytes + lastBytes == original && lastJSON?["complete"] as? Bool == true, "chunks reconstruct exact exported content")
            suite.expect(fixture.exportFD == -1 && fixture.exportState == "consumed", "completed export is closed")
            fixture.recordingDidExport(id: id, url: url)
            fixture.exportState = "ready"
            fixture.allowed = false
            suite.expect(fixture.readExport(offset: 0).error == "capture_content_disabled" && fixture.exportFD == -1, "revocation closes file and denies read")
            fixture.allowed = true
            fixture.recordingDidExport(id: id, url: url)
            fixture.clearExport(state: "denied")
            suite.expect(fixture.readExport(offset: 0).error == "export_not_ready", "denial removes export")
            fixture.recordingDidExport(id: id, url: url)
            fixture.exportExpiry = Date(timeIntervalSinceNow: -1)
            fixture.expireExportIfNeeded()
            suite.expect(fixture.exportFD == -1 && fixture.readExport(offset: 0).error == "export_not_ready", "expiry closes export")
            fixture.recordingDidExport(id: id, url: url)
            fixture.exportState = "ready"
            try Data([1, 2, 3]).write(to: url, options: [])
            suite.expect(fixture.readExport(offset: 0).error == "export_changed", "modified export rejected")
            try original.write(to: url)
            fixture.recordingDidExport(id: id, url: url)
            fixture.exportState = "ready"
            let replacement = folder.appendingPathComponent("replacement.mp4")
            try Data([7]).write(to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
            let pinned = fixture.readExport(offset: 0)
            let pinnedJSON = (try? JSONSerialization.jsonObject(with: Data((pinned.payload ?? "").utf8))) as? [String: Any]
            suite.expect(Data(base64Encoded: pinnedJSON?["data_base64"] as? String ?? "") == original.prefix(6144), "path replacement cannot switch the opened export")
        } catch {
            suite.expect(false, "recording export fixture: \(error)")
        }
    }
}
