// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import MCP

let server = Server(name: "Vorssaint", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
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
let windowActions = MCPDisplayWindowPolicy.windowActions.sorted()
let windowActionSchema: Value = .object(["type": .string("string"), "enum": .array(windowActions.map(Value.string))])
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
    default:
        return .init(content: [.text("Unknown tool or invalid arguments")], isError: true)
    }
    do {
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
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
