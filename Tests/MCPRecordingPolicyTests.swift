// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MCPRecordingPolicyTests {
    static func run(_ suite: TestSuite) {
        let owner = UUID()
        suite.expect(MCPRecordingPolicy.owned(owner.uuidString, owner: owner), "recording owner accepted")
        suite.expect(!MCPRecordingPolicy.owned(UUID().uuidString, owner: owner), "other recording rejected")
        suite.expect(!MCPRecordingPolicy.owned("bad", owner: owner), "invalid recording id rejected")
        suite.expect(!MCPRecordingPolicy.owned(owner.uuidString, owner: nil), "missing owner rejected")
        suite.expect(MCPRecordingPolicy.pauseAction("pause") == true, "explicit pause")
        suite.expect(MCPRecordingPolicy.pauseAction("resume") == false, "explicit resume")
        suite.expect(MCPRecordingPolicy.pauseAction("toggle") == nil, "ambiguous toggle rejected")
        suite.expect(MCPRecordingPolicy.mime(forExtension: "MOV") == "video/quicktime", "direct recording mime")
        suite.expect(MCPRecordingPolicy.mime(forExtension: "mp4") == "video/mp4", "exported video mime")
        suite.expect(MCPRecordingPolicy.mime(forExtension: "gif") == "image/gif", "exported gif mime")
        suite.expect(MCPRecordingPolicy.mime(forExtension: "txt") == nil, "unrelated file type rejected")
        suite.expect(MCPRecordingPolicy.validSize(1) && MCPRecordingPolicy.validSize(MCPRecordingPolicy.maxBytes), "recording size bounds accepted")
        suite.expect(!MCPRecordingPolicy.validSize(0) && !MCPRecordingPolicy.validSize(MCPRecordingPolicy.maxBytes + 1), "empty and oversized recording rejected")
        suite.expect(MCPRecordingPolicy.validOffset(0, next: 0, size: 1), "initial chunk accepted")
        suite.expect(!MCPRecordingPolicy.validOffset(1, next: 0, size: 2), "out-of-order chunk rejected")
        suite.expect(!MCPRecordingPolicy.validOffset(2, next: 2, size: 2), "read beyond end rejected")
        suite.expect(!MCPRecordingPolicy.validOffset(-1, next: -1, size: 2), "negative offset rejected")
    }
}
