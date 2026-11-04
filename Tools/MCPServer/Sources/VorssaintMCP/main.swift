// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import MCP

let server = Server(name: "Vorssaint", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
let emptySchema: Value = .object([
    "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)
])
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
             annotations: .init(destructiveHint: false, idempotentHint: true, openWorldHint: false))
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
    default:
        return .init(content: [.text("Unknown tool or invalid arguments")], isError: true)
    }
    do {
        let response = try MCPIPCClient.call(request)
        let data = try JSONEncoder().encode(response)
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: !response.ok)
    } catch {
        return .init(content: [.text("Vorssaint MCP control is unavailable. Open Vorssaint and enable MCP control in settings.")], isError: true)
    }
}
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
