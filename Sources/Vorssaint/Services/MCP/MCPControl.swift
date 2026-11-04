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
    }
}
