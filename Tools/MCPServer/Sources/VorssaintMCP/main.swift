// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import MCP

let server = Server(name: "Vorssaint", version: "0.1.0", capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
let emptySchema: Value = .object([
    "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)
])
func schema(_ properties: [String: Value], required: [String]) -> Value {
    .object(["type": .string("object"), "properties": .object(properties),
             "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)])
}
let stringSchema: Value = .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(512),
                                   "description": .string("At most 512 UTF-8 bytes.")])
func numberSchema(_ maximum: Int) -> Value {
    .object(["type": .string("number"), "minimum": .int(0), "maximum": .int(maximum)])
}
let boolSchema: Value = .object(["type": .string("boolean")])
let offsetSchema: Value = .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_000_000)])
let captureModeSchema: Value = .object(["type": .string("string"), "enum": .array(["screenshot", "text", "qr"].map(Value.string))])
let windowActions = MCPDisplayWindowPolicy.windowActions.sorted()
let windowActionSchema: Value = .object(["type": .string("string"), "enum": .array(windowActions.map(Value.string))])

/// Read only a user-approved, bounded result through the app's one-shot IPC.
/// Every chunk is reauthorized by the running app; do not write it to disk.
private struct ApprovedReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func readApprovedBytes(id: String, command: String, maxBytes: Int, acceptedTypes: Set<String>) throws -> (Data, String) {
    let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
    var data = Data()
    var expectedTotal: Int?
    var mimeType: String?
    while true {
        guard !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else {
            throw MCPIPCError.unavailable
        }
        let response = try MCPIPCClient.call(MCPIPCRequest(command: command, id: id, offset: data.count))
        guard response.ok else {
            throw ApprovedReadError(message: response.error ?? "Result is unavailable")
        }
        guard let payload = response.payload?.data(using: .utf8),
              let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              fields["id"] as? String == id,
              let offset = fields["offset"] as? Int, offset == data.count,
              let total = fields["total_bytes"] as? Int, (0...maxBytes).contains(total),
              let mime = fields["mime_type"] as? String,
              acceptedTypes.contains(mime),
              let encoded = fields["data_base64"] as? String,
              let chunk = Data(base64Encoded: encoded), chunk.count <= 6144,
              let complete = fields["complete"] as? Bool,
              (expectedTotal == nil || expectedTotal == total), (mimeType == nil || mimeType == mime),
              data.count + chunk.count <= total else { throw MCPIPCError.invalidMessage }
        expectedTotal = total; mimeType = mime
        data.append(chunk)
        if complete {
            guard data.count == total else { throw MCPIPCError.invalidMessage }
            return (data, mime)
        }
        guard !chunk.isEmpty, data.count < total, fields["next_offset"] as? Int == data.count else {
            throw MCPIPCError.invalidMessage
        }
    }
}

func readCapture(id: String) throws -> CallTool.Result {
    let (data, mime) = try readApprovedBytes(id: id, command: "capture_read", maxBytes: 8 * 1024 * 1024,
                                              acceptedTypes: ["image/png", "text/plain; charset=utf-8"])
    if mime == "image/png" {
        return .init(content: [.image(data: data.base64EncodedString(), mimeType: mime, metadata: nil)], isError: false)
    }
    guard let text = String(data: data, encoding: .utf8) else { throw MCPIPCError.invalidMessage }
    return .init(content: [.text(text)], isError: false)
}
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(name: "keep_awake_status", description: "Get the current Keep Awake state in Vorssaint.", inputSchema: emptySchema,
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "keep_awake_start", description: "Start or replace the current Keep Awake session with a manual session for the specified minutes; zero means until stopped. Existing user settings such as clamshell and mouse jiggle apply, and the chosen duration is saved.", inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["minutes": .object(["type": .string("integer"), "enum": .array([0, 15, 30, 60, 120, 240, 480].map(Value.int))])]),
            "required": .array([.string("minutes")]), "additionalProperties": .bool(false)
        ]), annotations: .init(destructiveHint: false, openWorldHint: false)),
        Tool(name: "keep_awake_stop", description: "Stop the current Keep Awake session, including an automatic session. Automatic activation is suppressed until its conditions clear or automation settings change.", inputSchema: emptySchema,
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "audio_status", description: "List audio output devices and mixer apps and read system volume and mute state. If truncated, use next_app_offset and next_output_offset to retrieve further entries. Values may be optimistic during an asynchronous write. Requires Sound access in Vorssaint's MCP settings.", inputSchema: schema(["app_offset": offsetSchema, "output_offset": offsetSchema], required: []),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "audio_set_system_volume", description: "Set the system output volume to a fraction from 0 to 1; setting zero can also mute the output. The hardware write is asynchronous.", inputSchema: schema(["value": numberSchema(1)], required: ["value"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "audio_set_system_mute", description: "Set the system output mute state; the hardware write is asynchronous.", inputSchema: schema(["muted": boolSchema], required: ["muted"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "audio_set_app_volume", description: "Set a mixer app's volume as a fraction from 0 to 2, using its ID from audio_status. The choice is saved; application is asynchronous.", inputSchema: schema(["id": stringSchema, "value": numberSchema(2)], required: ["id", "value"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "audio_set_output", description: "Set the system's default audio output by device ID from audio_status, preserving explicit per-app routes. The write is asynchronous.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "audio_set_app_output", description: "Set a mixer app's output by IDs from audio_status; omit output_id to use the system default. The route is saved and applied asynchronously.", inputSchema: schema(["id": stringSchema, "output_id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "display_list", description: "List available displays and reported brightness. If truncated, use next_offset for further entries. Brightness can be cached or optimistic. Requires Displays access in Vorssaint's MCP settings.", inputSchema: schema(["offset": offsetSchema], required: []),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "display_set_brightness", description: "Request display brightness as a fraction from 0 to 1 using an ID from display_list. The hardware write is asynchronous and acceptance is not proof of application.", inputSchema: schema(["id": stringSchema, "value": numberSchema(1)], required: ["id", "value"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "window_active", description: "Identify the frontmost application for a window layout action. Requires Window access and macOS Accessibility permission.", inputSchema: emptySchema,
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "window_layout", description: "Apply a layout to the currently focused window, only if its frontmost application's PID matches the ID returned by window_active. Focus can still change between windows of that application. Moving displays and restore are not idempotent.", inputSchema: schema(["id": stringSchema, "action": windowActionSchema], required: ["id", "action"]),
             annotations: .init(destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(name: "capture_start", description: "Ask the user to select a screen area for a screenshot, OCR, or QR. The user must separately approve transferring the unedited result. Requires Screen Capture and Share Capture Results in MCP settings and macOS Screen Recording access. Poll capture_status with the returned ID.", inputSchema: schema(["mode": captureModeSchema], required: ["mode"]),
             annotations: .init(destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(name: "capture_status", description: "Get the state of this capture request by ID: selecting, awaitingApproval, processing, ready, denied, cancelled, or failed.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "capture_read", description: "Retrieve the explicitly user-approved result once, by capture ID. Returns a PNG image or recognized text; results expire and are cleared after retrieval.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(name: "capture_discard", description: "Cancel and discard this capture request and its in-memory result by ID.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "recording_start", description: "Ask the user to select a recording area. Audio defaults to off; system_audio and microphone set the initial visible choices. Does not stop an existing recording. Returns a request ID.", inputSchema: schema(["system_audio": boolSchema, "microphone": boolSchema], required: []),
             annotations: .init(destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(name: "recording_status", description: "Read the status of a recording started by this MCP integration, including whether a user-exported result has been approved for sharing. When export_state is ready, use resources/read with vorssaint://recording/<id>.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "recording_stop", description: "Stop only the recording associated with this request ID; the app finalizes it using its normal editor or save workflow.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "recording_set_paused", description: "Pause or resume only the recording associated with this request ID.", inputSchema: schema(["id": stringSchema, "paused": boolSchema], required: ["id", "paused"]),
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "recording_share", description: "Ask the user to approve sharing the already saved or exported recording for this request. A direct save may contain the unedited recording. Poll recording_status; when ready read the one-shot MCP resource vorssaint://recording/<id>.", inputSchema: schema(["id": stringSchema], required: ["id"]),
             annotations: .init(destructiveHint: false, idempotentHint: false, openWorldHint: false))
    ])
}
await server.withMethodHandler(CallTool.self) { params in
    let arguments = params.arguments ?? [:]
    let request: MCPIPCRequest
    switch params.name {
    case "keep_awake_status" where arguments.isEmpty:
        request = MCPIPCRequest(command: "status")
    case "keep_awake_stop" where arguments.isEmpty:
        request = MCPIPCRequest(command: "stop")
    case "keep_awake_start":
        guard arguments.count == 1, let minutes = arguments["minutes"]?.intValue,
              [0, 15, 30, 60, 120, 240, 480].contains(minutes) else {
            return .init(content: [.text("minutes must be one of 0, 15, 30, 60, 120, 240, or 480")], isError: true)
        }
        request = MCPIPCRequest(command: "start", minutes: minutes)
    case "window_active" where arguments.isEmpty:
        request = MCPIPCRequest(command: params.name)
    case "audio_status", "display_list":
        let allowed: Set<String> = params.name == "audio_status" ? ["app_offset", "output_offset"] : ["offset"]
        guard Set(arguments.keys).isSubset(of: allowed), arguments.allSatisfy({ _, value in
            guard let offset = value.intValue else { return false }
            return (0...1_000_000).contains(offset)
        }) else {
            return .init(content: [.text("Offsets must be integers from 0 to 1000000")], isError: true)
        }
        request = MCPIPCRequest(command: params.name,
            offset: arguments[params.name == "audio_status" ? "app_offset" : "offset"]?.intValue,
            outputOffset: arguments["output_offset"]?.intValue)
    case "audio_set_system_volume", "audio_set_app_volume", "display_set_brightness":
        let needsID = params.name != "audio_set_system_volume"
        let expectedKeys: Set<String> = needsID ? ["id", "value"] : ["value"]
        let value = arguments["value"]?.doubleValue ?? arguments["value"]?.intValue.map(Double.init)
        let id = arguments["id"]?.stringValue
        let maxValue = params.name == "audio_set_app_volume" ? 2.0 : 1.0
        guard Set(arguments.keys) == expectedKeys, let value, value.isFinite,
              (0...maxValue).contains(value), !needsID || (id != nil && !id!.isEmpty && id!.utf8.count <= 512),
              params.name != "display_set_brightness" || MCPDisplayWindowPolicy.displayID(id) != nil else {
            return .init(content: [.text("Invalid ID or volume/brightness value")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id, value: value)
    case "audio_set_system_mute":
        guard Set(arguments.keys) == ["muted"], let muted = arguments["muted"]?.boolValue else {
            return .init(content: [.text("muted must be a boolean")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, muted: muted)
    case "audio_set_output":
        guard Set(arguments.keys) == ["id"], let id = arguments["id"]?.stringValue,
              !id.isEmpty, id.utf8.count <= 512 else {
            return .init(content: [.text("Invalid device ID")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id)
    case "audio_set_app_output":
        let keys = Set(arguments.keys)
        guard (keys == ["id"] || keys == ["id", "output_id"]),
              let id = arguments["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 512 else {
            return .init(content: [.text("Invalid app or output ID")], isError: true)
        }
        let output = arguments["output_id"]?.stringValue
        guard keys == ["id"] || (output != nil && !output!.isEmpty && output!.utf8.count <= 512) else {
            return .init(content: [.text("Invalid output ID")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id, action: output)
    case "window_layout":
        guard Set(arguments.keys) == ["id", "action"], let id = arguments["id"]?.stringValue,
              let action = arguments["action"]?.stringValue, !id.isEmpty, id.utf8.count <= 512,
              MCPDisplayWindowPolicy.processID(id) != nil,
              windowActions.contains(action) else {
            return .init(content: [.text("Invalid window ID or action")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id, action: action)
    case "capture_start":
        guard Set(arguments.keys) == ["mode"], let mode = arguments["mode"]?.stringValue,
              ["screenshot", "text", "qr"].contains(mode) else {
            return .init(content: [.text("Invalid capture mode")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, action: mode)
    case "capture_status", "capture_read", "capture_discard", "recording_status", "recording_stop", "recording_share":
        guard Set(arguments.keys) == ["id"], let id = arguments["id"]?.stringValue,
              UUID(uuidString: id) != nil else {
            return .init(content: [.text("A valid request ID is required")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id)
    case "recording_start":
        let keys = Set(arguments.keys)
        guard keys.isSubset(of: ["system_audio", "microphone"]),
              (arguments["system_audio"] == nil || arguments["system_audio"]?.boolValue != nil),
              (arguments["microphone"] == nil || arguments["microphone"]?.boolValue != nil) else {
            return .init(content: [.text("Audio choices must be booleans")], isError: true)
        }
        request = MCPIPCRequest(command: params.name,
                                systemAudio: arguments["system_audio"]?.boolValue,
                                microphone: arguments["microphone"]?.boolValue)
    case "recording_set_paused":
        guard Set(arguments.keys) == ["id", "paused"], let id = arguments["id"]?.stringValue,
              UUID(uuidString: id) != nil, let paused = arguments["paused"]?.boolValue else {
            return .init(content: [.text("A valid request ID and paused boolean are required")], isError: true)
        }
        request = MCPIPCRequest(command: params.name, id: id, action: paused ? "pause" : "resume")
    default:
        return .init(content: [.text("Unknown tool or invalid arguments")], isError: true)
    }
    do {
        if params.name == "capture_read", let id = request.id {
            do { return try readCapture(id: id) }
            catch let error as ApprovedReadError {
                return .init(content: [.text(error.message)], isError: true)
            }
        }
        let response = try MCPIPCClient.call(request)
        let encoded = try JSONEncoder().encode(response)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw MCPIPCError.invalidMessage
        }
        if let payload = response.payload {
            object["payload"] = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: !response.ok)
    } catch {
        return .init(content: [.text("Vorssaint MCP control is unavailable. Open Vorssaint and enable MCP control in settings.")], isError: true)
    }
}
await server.withMethodHandler(ListResources.self) { _ in
    // Exported results are private, per-request and not enumerable.
    .init(resources: [])
}
await server.withMethodHandler(ListResourceTemplates.self) { _ in
    .init(templates: [.init(uriTemplate: "vorssaint://recording/{id}", name: "Approved recording export",
                            description: "One-shot user-approved, saved recording. Request sharing and wait for approval first.")])
}
await server.withMethodHandler(ReadResource.self) { params in
    let prefix = "vorssaint://recording/"
    guard params.uri.hasPrefix(prefix) else { throw MCPError.invalidParams("Unknown resource") }
    let rawID = String(params.uri.dropFirst(prefix.count))
    guard let recordingID = UUID(uuidString: rawID) else { throw MCPError.invalidParams("Invalid recording ID") }
    let id = recordingID.uuidString
    do {
        let (data, mime) = try readApprovedBytes(id: id, command: "recording_read", maxBytes: 32 * 1024 * 1024,
                                                  acceptedTypes: ["video/quicktime", "video/mp4", "image/gif"])
        return .init(contents: [.binary(data, uri: params.uri, mimeType: mime)])
    } catch let error as ApprovedReadError {
        throw MCPError.invalidRequest(error.message)
    } catch {
        throw MCPError.internalError("Could not read approved recording")
    }
}
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
