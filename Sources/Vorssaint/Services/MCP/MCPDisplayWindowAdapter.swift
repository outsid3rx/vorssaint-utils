// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Foundation

/// Adapts the app's live display and window services on the main thread.
enum MCPDisplayWindowAdapter {
    private struct Display: Encodable {
        let id: String
        let name: String
        let is_builtin: Bool
        let active: Bool
        let method: String?
        let brightness: Double
        let readable: Bool
        let pending: Bool
    }
    private struct DisplayList: Encodable {
        let displays: [Display]
        let total: Int
        let offset: Int
        let next_offset: Int?
        let truncated: Bool
    }
    private struct BrightnessQueued: Encodable { let id: String; let value: Double; let status = "queued" }
    private struct Frontmost: Encodable { let pid: String; let name: String?; let bundle_id: String? }
    private struct WindowApplied: Encodable { let pid: String; let action: String; let restored: Bool; let status = "applied" }

    private static func response<T: Encodable>(_ payload: T) -> MCPIPCResponse {
        guard let data = try? JSONEncoder().encode(payload),
              let value = String(data: data, encoding: .utf8) else {
            return MCPIPCResponse(ok: false, error: "encoding_failed")
        }
        return MCPIPCResponse(ok: true, payload: value)
    }

    static func execute(_ request: MCPIPCRequest) -> MCPIPCResponse? {
        precondition(Thread.isMainThread)
        switch request.command {
        case "display_list":
            guard request.minutes == nil, request.id == nil, request.value == nil,
                  request.action == nil, request.muted == nil, request.outputOffset == nil,
                  (0...1_000_000).contains(request.offset ?? 0) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard AppFeature.brightness.isAvailable,
                  UserDefaults.standard.bool(forKey: DefaultsKey.brightnessControlEnabled) else {
                return MCPIPCResponse(ok: false, error: "display_control_unavailable")
            }
            let service = BrightnessService.shared
            let total = service.displays.count
            guard let offset = MCPDisplayWindowPolicy.displayPageOffset(request.offset, total: total) else {
                return MCPIPCResponse(ok: false, error: "invalid_offset")
            }
            var displays = service.displays.dropFirst(offset).prefix(32).map { display in
                let method: String?
                switch display.method {
                case .system: method = "system"
                case .ddc: method = "ddc"
                case .software: method = "software"
                case nil: method = nil
                }
                return Display(id: String(display.id), name: display.name,
                               is_builtin: display.isBuiltIn, active: display.isActive,
                               method: method, brightness: display.brightness,
                               readable: display.readable,
                               pending: service.pendingDisplayIDs.contains(display.id))
            }
            // Account for both JSON encoding layers in the IPC frame limit.
            while true {
                let end = offset + displays.count
                let hasMore = end < total
                let result = response(DisplayList(displays: displays, total: total, offset: offset,
                                                  next_offset: hasMore ? end : nil, truncated: hasMore))
                guard result.ok else { return result }
                guard let data = try? JSONEncoder().encode(result) else {
                    return MCPIPCResponse(ok: false, error: "encoding_failed")
                }
                if data.count <= 16_384 { return result }
                guard displays.count > 1 else { return MCPIPCResponse(ok: false, error: "response_too_large") }
                displays.removeLast()
            }

        case "display_set_brightness":
            guard request.minutes == nil, request.action == nil, request.muted == nil,
                  request.offset == nil, request.outputOffset == nil,
                  let id = MCPDisplayWindowPolicy.displayID(request.id),
                  let value = MCPDisplayWindowPolicy.brightness(request.value) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard AppFeature.brightness.isAvailable,
                  UserDefaults.standard.bool(forKey: DefaultsKey.brightnessControlEnabled) else {
                return MCPIPCResponse(ok: false, error: "display_control_unavailable")
            }
            let service = BrightnessService.shared
            guard let display = service.displays.first(where: { $0.id == id }),
                  MCPDisplayWindowPolicy.canSetBrightness(
                    active: display.isActive, hasRoute: display.method != nil,
                    pending: service.pendingDisplayIDs.contains(id)) else {
                return MCPIPCResponse(ok: false, error: "display_unavailable")
            }
            service.setBrightness(value, for: id, announces: false)
            // The service queues an asynchronous hardware write and updates
            // the slider optimistically. This is not a read-back or success.
            return response(BrightnessQueued(id: String(id), value: value))

        case "window_active":
            guard request.minutes == nil, request.id == nil, request.value == nil,
                  request.action == nil, request.muted == nil, request.offset == nil,
                  request.outputOffset == nil else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard AppFeature.windowLayout.isAvailable else {
                return MCPIPCResponse(ok: false, error: "window_layout_unavailable")
            }
            guard SessionActivity.shared.isActive else { return MCPIPCResponse(ok: false, error: "session_inactive") }
            guard AXIsProcessTrusted() else { return MCPIPCResponse(ok: false, error: "missing_accessibility") }
            guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else {
                return MCPIPCResponse(ok: false, error: "no_active_app")
            }
            return response(Frontmost(pid: String(app.processIdentifier), name: app.localizedName,
                                      bundle_id: app.bundleIdentifier))

        case "window_layout":
            guard request.minutes == nil, request.value == nil, request.muted == nil,
                  request.offset == nil, request.outputOffset == nil,
                  let pid = MCPDisplayWindowPolicy.processID(request.id),
                  let rawAction = MCPDisplayWindowPolicy.action(request.action),
                  let action = WindowLayoutAction(rawValue: rawAction) else {
                return MCPIPCResponse(ok: false, error: "invalid_arguments")
            }
            guard AppFeature.windowLayout.isAvailable else {
                return MCPIPCResponse(ok: false, error: "window_layout_unavailable")
            }
            guard SessionActivity.shared.isActive else { return MCPIPCResponse(ok: false, error: "session_inactive") }
            guard AXIsProcessTrusted() else { return MCPIPCResponse(ok: false, error: "missing_accessibility") }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return MCPIPCResponse(ok: false, error: "active_app_changed")
            }
            switch WindowLayoutService.shared.apply(action, expectedFrontmostPID: pid) {
            case .success(let restored): return response(WindowApplied(pid: String(pid), action: rawAction, restored: restored))
            case .failure(.missingAccessibility): return MCPIPCResponse(ok: false, error: "missing_accessibility")
            case .failure(.noWindow): return MCPIPCResponse(ok: false, error: "no_focused_window_or_app_changed")
            case .failure(.noRestore): return MCPIPCResponse(ok: false, error: "no_restore")
            case .failure(.failed): return MCPIPCResponse(ok: false, error: "window_operation_failed")
            case .failure(.sessionInactive): return MCPIPCResponse(ok: false, error: "session_inactive")
            case .failure(.ignoredApp): return MCPIPCResponse(ok: false, error: "app_ignored")
            case .failure(.mcpDisabled): return MCPIPCResponse(ok: false, error: "category_disabled")
            }
        default:
            return nil
        }
    }
}
