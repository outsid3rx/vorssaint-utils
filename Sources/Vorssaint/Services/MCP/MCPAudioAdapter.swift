// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Narrow MCP adapter for the live mixer. A queued command is not a claim that
/// the audio device has already applied it; app routes and gain may need an
/// asynchronous engine rebuild or system permission.
enum MCPAudioAdapter {
    private static let commands: Set<String> = [
        "audio_status", "audio_set_system_volume", "audio_set_system_mute",
        "audio_set_app_volume", "audio_set_output", "audio_set_app_output"
    ]

    static func execute(_ request: MCPIPCRequest) -> MCPIPCResponse? {
        guard commands.contains(request.command) else { return nil }
        precondition(Thread.isMainThread)
        guard AppFeature.mixer.isAvailable else { return MCPIPCResponse(ok: false, error: "feature_unavailable") }
        guard AppVolumeMixer.isSupported else { return MCPIPCResponse(ok: false, error: "unsupported_macos") }
        let mixer = AppVolumeMixer.shared
        guard request.minutes == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
        guard request.command == "audio_status" || (request.offset == nil && request.outputOffset == nil) else {
            return MCPIPCResponse(ok: false, error: "invalid_arguments")
        }
        switch request.command {
        case "audio_status":
            guard request.id == nil, request.value == nil, request.action == nil, request.muted == nil else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            let appOffset = request.offset ?? 0
            let outputOffset = request.outputOffset ?? 0
            let totalApps = mixer.apps.count
            let totalOutputs = mixer.outputDevices.count
            guard (0...1_000_000).contains(appOffset), appOffset <= totalApps,
                  (0...1_000_000).contains(outputOffset), outputOffset <= totalOutputs else {
                return MCPIPCResponse(ok: false, error: "invalid_offset")
            }
            var apps: [[String: Any]] = mixer.apps.dropFirst(appOffset).prefix(32).map { app in
                ["id": app.id, "name": app.name, "is_playing": app.isPlaying,
                 "is_bypassed": app.isBypassed, "volume": app.volume,
                 "selected_output_uid": app.selectedOutputDeviceUID as Any? ?? NSNull(),
                 "effective_output_uid": app.effectiveOutputDeviceUID as Any? ?? NSNull(),
                 "output_unavailable": app.outputDeviceUnavailable]
            }
            var outputs: [[String: Any]] = mixer.outputDevices.dropFirst(outputOffset).prefix(32).map { device in
                ["uid": device.uid, "name": device.name, "is_default": device.isDefault,
                 "is_headphones": device.isHeadphones,
                 "can_be_default_output": device.canBeDefaultOutput,
                 "can_be_system_sound_output": device.canBeDefaultSystemOutput]
            }
            // The IPC frame has a 16 KiB limit. Count the final encoded
            // response (which escapes the nested JSON) and reduce the list
            // if needed; never silently present a partial snapshot as complete.
            while true {
                let nextAppOffset = appOffset + apps.count
                let nextOutputOffset = outputOffset + outputs.count
                let result = response(["apps": apps, "outputs": outputs,
                    "total_apps": totalApps, "total_outputs": totalOutputs,
                    "app_offset": appOffset, "output_offset": outputOffset,
                    "next_app_offset": nextAppOffset < totalApps ? nextAppOffset as Any : NSNull(),
                    "next_output_offset": nextOutputOffset < totalOutputs ? nextOutputOffset as Any : NSNull(),
                    "truncated": nextAppOffset < totalApps || nextOutputOffset < totalOutputs,
                    "current_output_uid": mixer.currentOutputDeviceUID as Any? ?? NSNull(),
                    "system_volume": mixer.systemOutputVolume as Any? ?? NSNull(),
                    "system_muted": mixer.systemOutputMuted as Any? ?? NSNull(),
                    "needs_permission": mixer.needsPermission])
                guard result.ok else { return result }
                guard let encoded = try? JSONEncoder().encode(result) else {
                    return MCPIPCResponse(ok: false, error: "serialization_failed")
                }
                if encoded.count <= 16_384 {
                    guard (appOffset == totalApps || !apps.isEmpty),
                          (outputOffset == totalOutputs || !outputs.isEmpty) else {
                        return MCPIPCResponse(ok: false, error: "response_too_large")
                    }
                    return result
                }
                if apps.count >= outputs.count && !apps.isEmpty { apps.removeLast() }
                else if !outputs.isEmpty { outputs.removeLast() }
                else if !apps.isEmpty { apps.removeLast() }
                else { return MCPIPCResponse(ok: false, error: "response_too_large") }
            }
        case "audio_set_system_volume":
            guard request.id == nil, request.action == nil, request.muted == nil,
                  let volume = request.value, MCPAudioPolicy.validSystemVolume(volume) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard mixer.systemOutputVolume != nil else { return MCPIPCResponse(ok: false, error: "volume_unavailable") }
            guard mixer.requestOutputAdjustment(volume: volume) else {
                return MCPIPCResponse(ok: false, error: "volume_unavailable")
            }
            return queued()
        case "audio_set_system_mute":
            guard request.id == nil, request.action == nil, request.value == nil,
                  let muted = request.muted else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            guard mixer.systemOutputMuted != nil else { return MCPIPCResponse(ok: false, error: "mute_unavailable") }
            guard mixer.requestOutputAdjustment(muted: muted) else {
                return MCPIPCResponse(ok: false, error: "mute_unavailable")
            }
            return queued()
        case "audio_set_app_volume":
            guard let id = request.id, MCPAudioPolicy.validIdentifier(id), let value = request.value,
                  MCPAudioPolicy.validAppVolume(value), request.action == nil, request.muted == nil else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard let app = mixer.apps.first(where: { $0.id == id }) else { return MCPIPCResponse(ok: false, error: "app_unavailable") }
            guard !app.isBypassed else { return MCPIPCResponse(ok: false, error: "app_bypassed") }
            mixer.setVolume(value, for: app)
            return queued()
        case "audio_set_output":
            guard let id = request.id, MCPAudioPolicy.validIdentifier(id), request.value == nil,
                  request.action == nil, request.muted == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            guard mixer.outputDevices.contains(where: { $0.uid == id && $0.canBeDefaultOutput }) else {
                return MCPIPCResponse(ok: false, error: "output_unavailable")
            }
            // This existing asynchronous path keeps each app's explicit route.
            mixer.setPriorityOutputDeviceUID(id)
            return queued()
        case "audio_set_app_output":
            guard let id = request.id, MCPAudioPolicy.validIdentifier(id), request.value == nil,
                  request.muted == nil else { return MCPIPCResponse(ok: false, error: "invalid_arguments") }
            guard let app = mixer.apps.first(where: { $0.id == id }) else { return MCPIPCResponse(ok: false, error: "app_unavailable") }
            guard !app.isBypassed else { return MCPIPCResponse(ok: false, error: "app_bypassed") }
            if let uid = request.action {
                // AirPlay sentinel choices can open a system picker as a side
                // effect. Only route directly to a concrete listed device.
                guard MCPAudioPolicy.validIdentifier(uid), !MixerRoutingSupport.isAirPlaySentinel(uid),
                      uid != MixerRoutingSupport.airPlaySpeakerChoiceID,
                      mixer.outputDevices.contains(where: { $0.uid == uid }) else {
                    return MCPIPCResponse(ok: false, error: "output_unavailable")
                }
            }
            mixer.setOutputDeviceUID(request.action, for: app)
            return queued()
        default:
            return nil
        }
    }

    private static func queued() -> MCPIPCResponse {
        response(["status": "requested", "confirmed": false])
    }

    private static func response(_ value: [String: Any]) -> MCPIPCResponse {
        guard JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: bytes, encoding: .utf8) else {
            return MCPIPCResponse(ok: false, error: "serialization_failed")
        }
        return MCPIPCResponse(ok: true, payload: json)
    }
}
