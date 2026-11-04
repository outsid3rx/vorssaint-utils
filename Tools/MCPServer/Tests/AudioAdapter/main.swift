// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct FakeFeature { var isAvailable = true }
enum AppFeature { static var mixer = FakeFeature() }
enum MixerRoutingSupport {
    static let airPlaySpeakerChoiceID = "choose-airplay"
    static func isAirPlaySentinel(_ uid: String) -> Bool { uid == "airplay" }
}
struct MixerApp {
    let id: String
    let name: String
    let isPlaying: Bool
    let isBypassed: Bool
    let selectedOutputDeviceUID: String?
    let effectiveOutputDeviceUID: String?
    let outputDeviceUnavailable: Bool
    let volume: Double
}
struct MixerOutputDevice {
    let uid: String
    let name: String
    let isDefault: Bool
    let isHeadphones: Bool
    let canBeDefaultOutput: Bool
    let canBeDefaultSystemOutput: Bool
}
final class AppVolumeMixer {
    static let shared = AppVolumeMixer()
    static var isSupported = true
    var apps = [MixerApp(id: "live", name: "Music", isPlaying: true, isBypassed: false,
                         selectedOutputDeviceUID: nil, effectiveOutputDeviceUID: "speaker", outputDeviceUnavailable: false, volume: 1),
                MixerApp(id: "bypassed", name: "Call", isPlaying: true, isBypassed: true,
                         selectedOutputDeviceUID: nil, effectiveOutputDeviceUID: nil, outputDeviceUnavailable: false, volume: 1)]
    var outputDevices = [MixerOutputDevice(uid: "speaker", name: "Speaker", isDefault: true,
                                           isHeadphones: false, canBeDefaultOutput: true, canBeDefaultSystemOutput: true)]
    var currentOutputDeviceUID: String? = "speaker"
    var systemOutputVolume: Double? = 0.5
    var systemOutputMuted: Bool? = false
    var needsPermission = false
    var requests: [String] = []
    var rejectOutputAdjustment = false
    @discardableResult
    func requestOutputAdjustment(volume: Double? = nil, muted: Bool? = nil,
                                 completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard !rejectOutputAdjustment else { completion(false); return false }
        requests.append("system")
        return true
    }
    func setVolume(_ value: Double, for app: MixerApp) { requests.append("app_volume") }
    func setPriorityOutputDeviceUID(_ id: String) { requests.append("output") }
    func setOutputDeviceUID(_ uid: String?, for app: MixerApp) { requests.append(uid ?? "default") }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("audio adapter: \(message)\n", stderr); exit(1) }
}
let m = AppVolumeMixer.shared
func call(_ request: MCPIPCRequest) -> MCPIPCResponse { MCPAudioAdapter.execute(request)! }
let status = call(MCPIPCRequest(command: "audio_status"))
check(status.ok, "status failed")
let data = status.payload!.data(using: .utf8)!
let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
check((snapshot["apps"] as? [[String: Any]])?.count == 2, "status lacks apps")
check((snapshot["outputs"] as? [[String: Any]])?.count == 1, "status lacks outputs")
for request in [MCPIPCRequest(command: "audio_set_system_volume", value: 2),
                MCPIPCRequest(command: "audio_set_app_volume", id: "live", value: 2.01),
                MCPIPCRequest(command: "audio_set_app_volume", id: "missing", value: 1),
                MCPIPCRequest(command: "audio_set_app_volume", id: "bypassed", value: 1),
                MCPIPCRequest(command: "audio_set_output", id: "unknown"),
                MCPIPCRequest(command: "audio_set_app_output", id: "live", action: "airplay"),
                MCPIPCRequest(command: "audio_set_output", id: "speaker", offset: 0),
                MCPIPCRequest(command: "audio_set_system_volume", value: 0.5, muted: true)] {
    check(!call(request).ok, "invalid request accepted")
}
check(m.requests.isEmpty, "invalid request changed audio")
m.rejectOutputAdjustment = true
check(!call(MCPIPCRequest(command: "audio_set_system_volume", value: 0.5)).ok,
      "immediately rejected system volume reported success")
check(!call(MCPIPCRequest(command: "audio_set_system_mute", muted: true)).ok,
      "immediately rejected mute reported success")
check(m.requests.isEmpty, "rejected system adjustment changed audio")
m.rejectOutputAdjustment = false
check(call(MCPIPCRequest(command: "audio_set_system_volume", value: 0)).ok, "valid system volume rejected")
check(call(MCPIPCRequest(command: "audio_set_system_mute", muted: true)).ok, "valid mute rejected")
check(call(MCPIPCRequest(command: "audio_set_app_volume", id: "live", value: 2)).ok, "valid app boost rejected")
check(call(MCPIPCRequest(command: "audio_set_output", id: "speaker")).ok, "valid output rejected")
check(call(MCPIPCRequest(command: "audio_set_app_output", id: "live")).ok, "default app output rejected")
check(m.requests == ["system", "system", "app_volume", "output", "default"], "valid commands were not forwarded correctly")
m.apps = (0..<300).map { index in
    MixerApp(id: "app-\(index)", name: String(repeating: "a", count: 200), isPlaying: true,
             isBypassed: false, selectedOutputDeviceUID: nil, effectiveOutputDeviceUID: nil,
             outputDeviceUnavailable: false, volume: 1)
}
let largeStatus = call(MCPIPCRequest(command: "audio_status"))
check(largeStatus.ok, "large status failed")
let largeSnapshot = try JSONSerialization.jsonObject(with: largeStatus.payload!.data(using: .utf8)!) as! [String: Any]
check(largeSnapshot["truncated"] as? Bool == true, "large status does not disclose truncation")
check(largeSnapshot["total_apps"] as? Int == 300, "large status lacks total count")
let next = largeSnapshot["next_app_offset"] as! Int
check(next > 0 && next < 300, "missing next application page")
let page = call(MCPIPCRequest(command: "audio_status", offset: next, outputOffset: 1))
let pageJSON = try JSONSerialization.jsonObject(with: page.payload!.data(using: .utf8)!) as! [String: Any]
check(pageJSON["app_offset"] as? Int == next && pageJSON["output_offset"] as? Int == 1,
      "incorrect page offsets")
check((pageJSON["apps"] as! [[String: Any]]).first?["id"] as? String == "app-\(next)",
      "pagination skipped or duplicated an app")
check(!call(MCPIPCRequest(command: "audio_status", offset: -1)).ok, "negative offset accepted")
check(!call(MCPIPCRequest(command: "audio_status", offset: 1_000_001)).ok, "oversized offset accepted")
check(!call(MCPIPCRequest(command: "audio_status", offset: 301)).ok, "offset past list accepted")
let encodedStatus = try JSONEncoder().encode(largeStatus)
check(encodedStatus.count <= 16384, "large status exceeds IPC frame limit")
m.apps = [MixerApp(id: "oversized", name: String(repeating: "x", count: 20_000), isPlaying: true,
                   isBypassed: false, selectedOutputDeviceUID: nil, effectiveOutputDeviceUID: nil,
                   outputDeviceUnavailable: false, volume: 1)]
let oversized = call(MCPIPCRequest(command: "audio_status", outputOffset: 1))
check(!oversized.ok && oversized.error == "response_too_large", "oversized entry yielded a nonprogressing cursor")
AppFeature.mixer.isAvailable = false
check(!call(MCPIPCRequest(command: "audio_set_output", id: "speaker")).ok, "disabled mixer accepted command")
check(m.requests.count == 5, "disabled mixer changed audio")
print("MCP audio adapter tests passed")
