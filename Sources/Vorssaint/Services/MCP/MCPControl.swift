// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Combine

/// Owns the optional local listener. Commands and preferences are checked on
/// the main thread immediately before touching the live application services.
final class MCPControl: ObservableObject {
    static let shared = MCPControl()
    @Published private(set) var lastError: String?
    private var server: MCPIPCServer?
    private var generation = 0

    func syncWithPreferences() {
        precondition(Thread.isMainThread)
        syncCapturePermissions()
        guard UserDefaults.standard.bool(forKey: DefaultsKey.mcpEnabled) else {
            generation &+= 1
            server?.stop()
            server = nil
            lastError = nil
            return
        }
        guard server == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        let listener = MCPIPCServer { [weak self] request in
            guard self?.generation == currentGeneration,
                  UserDefaults.standard.bool(forKey: DefaultsKey.mcpEnabled) else {
                return MCPIPCResponse(ok: false, error: "disabled")
            }
            if !request.command.hasPrefix("recording_"),
               request.systemAudio != nil || request.microphone != nil {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            if request.command.hasPrefix("capture_") {
                guard UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureEnabled) else {
                    return MCPIPCResponse(ok: false, error: "capture_disabled")
                }
                if request.command == "capture_read",
                   !UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureContentEnabled) {
                    return MCPIPCResponse(ok: false, error: "capture_content_disabled")
                }
                return MCPCaptureAdapter.shared.execute(request) ?? MCPIPCResponse(ok: false, error: "invalid_command")
            }
            if request.command.hasPrefix("recording_") {
                guard UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureEnabled),
                      UserDefaults.standard.bool(forKey: DefaultsKey.mcpRecordingEnabled) else {
                    return MCPIPCResponse(ok: false, error: "recording_disabled")
                }
                if ["recording_share", "recording_read"].contains(request.command),
                   !UserDefaults.standard.bool(forKey: DefaultsKey.mcpCaptureContentEnabled) {
                    return MCPIPCResponse(ok: false, error: "capture_content_disabled")
                }
                return MCPRecordingAdapter.shared.execute(request) ?? MCPIPCResponse(ok: false, error: "invalid_command")
            }
            if request.command.hasPrefix("audio_") {
                guard UserDefaults.standard.bool(forKey: DefaultsKey.mcpAudioEnabled) else {
                    return MCPIPCResponse(ok: false, error: "audio_disabled")
                }
                return MCPAudioAdapter.execute(request) ?? MCPIPCResponse(ok: false, error: "invalid_command")
            }
            if request.command.hasPrefix("display_") || request.command.hasPrefix("window_") {
                let key = request.command.hasPrefix("display_") ? DefaultsKey.mcpDisplayEnabled : DefaultsKey.mcpWindowEnabled
                guard UserDefaults.standard.bool(forKey: key) else {
                    return MCPIPCResponse(ok: false, error: "category_disabled")
                }
                return MCPDisplayWindowAdapter.execute(request) ?? MCPIPCResponse(ok: false, error: "invalid_command")
            }
            guard request.id == nil, request.value == nil, request.action == nil, request.muted == nil,
                  request.offset == nil, request.outputOffset == nil else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            let command: MCPKeepAwakeCommand
            switch request.command {
            case "status" where request.minutes == nil: command = .status
            case "start":
                guard let minutes = request.minutes else { return MCPIPCResponse(ok: false, error: "invalid_duration") }
                command = .start(minutes: minutes)
            case "stop" where request.minutes == nil: command = .stop
            default: return MCPIPCResponse(ok: false, error: "invalid_command")
            }
            switch MCPKeepAwakeAdapter.live().execute(command) {
            case .failure(let error):
                switch error {
                case .unavailable: return MCPIPCResponse(ok: false, error: "unavailable")
                case .invalidDuration: return MCPIPCResponse(ok: false, error: "invalid_duration")
                case .activationFailed: return MCPIPCResponse(ok: false, error: "activation_failed")
                }
            case .success(let state):
                return MCPIPCResponse(ok: true, available: state.available, active: state.active,
                                      endDate: state.endDate.map { ISO8601DateFormatter().string(from: $0) },
                                      sessionTrigger: state.trigger)
            }
        }
        do {
            try listener.start()
            server = listener
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        generation &+= 1
        server?.stop()
        server = nil
        MCPCaptureAdapter.shared.clear()
        MCPRecordingAdapter.shared.stopOwnedCapture()
    }

    func syncCapturePermissions() {
        precondition(Thread.isMainThread)
        MCPCaptureAdapter.shared.syncWithPermissions()
        MCPRecordingAdapter.shared.syncWithPermissions()
    }
}
