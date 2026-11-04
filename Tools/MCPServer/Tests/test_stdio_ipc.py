#!/usr/bin/env python3
"""Exercise MCP stdio through an isolated mock IPC listener.

Build the server with -Xswiftc -DVORSSAINT_MCP_TEST first, then pass its path
as the sole argument. The test flag makes its socket path process-specific.
"""
import json
import os
import select
import socket
import subprocess
import sys
import threading

server = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, bufsize=1)
path = f"/tmp/vorssaint-mcp-test-{os.getuid()}-{server.pid}"
received = []
# Each request is compared in full, including the absence of optional keys.
valid = [
    ("keep_awake_status", {}, {"command": "status"}, {"ok": True, "available": True, "active": False}),
    ("keep_awake_start", {"minutes": 15}, {"command": "start", "minutes": 15}, {"ok": True, "available": True, "active": True}),
    ("keep_awake_stop", {}, {"command": "stop"}, {"ok": True, "available": True, "active": False}),
    ("audio_status", {}, {"command": "audio_status"}, {"ok": True, "payload": '{"apps":[]}'}),
    ("audio_status", {"app_offset": 50}, {"command": "audio_status", "offset": 50}, {"ok": True, "payload": '{"apps":[],"app_offset":50}'}),
    ("audio_status", {"app_offset": 50, "output_offset": 100}, {"command": "audio_status", "offset": 50, "outputOffset": 100}, {"ok": True, "payload": '{"apps":[],"app_offset":50,"output_offset":100}'}),
    ("audio_status", {"output_offset": 1000000}, {"command": "audio_status", "outputOffset": 1000000}, {"ok": True, "payload": '{"outputs":[],"output_offset":1000000}'}),
    ("audio_set_system_volume", {"value": 0.5}, {"command": "audio_set_system_volume", "value": 0.5}, {"ok": True}),
    ("audio_set_system_mute", {"muted": True}, {"command": "audio_set_system_mute", "muted": True}, {"ok": True}),
    ("audio_set_app_volume", {"id": "app-id", "value": 1.5}, {"command": "audio_set_app_volume", "id": "app-id", "value": 1.5}, {"ok": True}),
    ("audio_set_output", {"id": "speaker"}, {"command": "audio_set_output", "id": "speaker"}, {"ok": True}),
    ("audio_set_app_output", {"id": "app-id", "output_id": "speaker"}, {"command": "audio_set_app_output", "id": "app-id", "action": "speaker"}, {"ok": True}),
    ("audio_set_app_output", {"id": "app-id"}, {"command": "audio_set_app_output", "id": "app-id"}, {"ok": True}),
    ("display_list", {}, {"command": "display_list"}, {"ok": True, "payload": '{"displays":[]}'}),
    ("display_list", {"offset": 50}, {"command": "display_list", "offset": 50}, {"ok": True, "payload": '{"displays":[],"offset":50}'}),
    ("display_list", {"offset": 0}, {"command": "display_list", "offset": 0}, {"ok": True, "payload": '{"displays":[],"offset":0}'}),
    ("display_set_brightness", {"id": "1", "value": 0.6}, {"command": "display_set_brightness", "id": "1", "value": 0.6}, {"ok": True}),
    ("window_active", {}, {"command": "window_active"}, {"ok": True, "payload": '{"pid":42}'}),
    ("window_layout", {"id": "42", "action": "leftHalf"}, {"command": "window_layout", "id": "42", "action": "leftHalf"}, {"ok": True}),
    ("window_layout", {"id": "42", "action": "nextDisplay"}, {"command": "window_layout", "id": "42", "action": "nextDisplay"}, {"ok": True}),
    ("window_layout", {"id": "999", "action": "restore"}, {"command": "window_layout", "id": "999", "action": "restore"}, {"ok": False, "error": "focus_changed"}),
]
invalid = [
    ("keep_awake_status", {"extra": 1}), ("keep_awake_start", {}),
    ("keep_awake_start", {"minutes": 7}), ("keep_awake_start", {"minutes": 15, "extra": 1}),
    ("keep_awake_stop", {"extra": 1}),
    ("audio_status", {"extra": 1}), ("audio_status", {"app_offset": -1}),
    ("audio_status", {"output_offset": 1000001}), ("audio_status", {"app_offset": 1.5}),
    ("audio_status", {"output_offset": "1"}), ("audio_status", {"app_offset": 0, "extra": 1}),
    ("audio_set_system_volume", {}), ("audio_set_system_volume", {"value": -0.01}),
    ("audio_set_system_volume", {"value": 1.01}), ("audio_set_system_volume", {"value": "0.5"}),
    ("audio_set_system_volume", {"value": 0.5, "extra": 1}),
    ("audio_set_system_mute", {}), ("audio_set_system_mute", {"muted": "true"}),
    ("audio_set_system_mute", {"muted": True, "extra": 1}),
    ("audio_set_app_volume", {"id": "app-id"}), ("audio_set_app_volume", {"id": "", "value": 1}),
    ("audio_set_app_volume", {"id": "app-id", "value": 2.01}),
    ("audio_set_app_volume", {"id": "app-id", "value": 1, "extra": 1}),
    ("audio_set_output", {}), ("audio_set_output", {"id": ""}),
    ("audio_set_output", {"id": "speaker", "extra": 1}),
    ("audio_set_app_output", {}), ("audio_set_app_output", {"id": "app-id", "output_id": ""}),
    ("audio_set_app_output", {"id": "app-id", "extra": 1}),
    ("display_list", {"extra": 1}), ("display_list", {"offset": -1}),
    ("display_list", {"offset": 1000001}), ("display_list", {"offset": 0.5}),
    ("display_list", {"offset": "1"}), ("display_list", {"offset": 0, "extra": 1}),
    ("display_set_brightness", {"id": "1"}), ("display_set_brightness", {"id": "0", "value": 0.5}),
    ("display_set_brightness", {"id": "1", "value": -0.01}),
    ("display_set_brightness", {"id": "1", "value": 1.01}),
    ("display_set_brightness", {"id": "1", "value": 0.5, "extra": 1}),
    ("window_active", {"extra": 1}),
    ("window_layout", {}), ("window_layout", {"id": "0", "action": "leftHalf"}),
    ("window_layout", {"id": "42", "action": "fullScreen"}),
    ("window_layout", {"id": "42", "action": "leftHalf", "extra": 1}),
]
try:
    os.mkdir(path, 0o700)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path + "/control.sock")
    listener.listen(3)
    listener.settimeout(10)
    errors = []

    def mock():
        try:
            for _, _, expected, response in valid:
                conn, _ = listener.accept()
                with conn:
                    data = b""
                    while not data.endswith(b"\n"):
                        part = conn.recv(4096)
                        if not part:
                            raise RuntimeError("early IPC EOF")
                        data += part
                    request = json.loads(data)
                    received.append(request)
                    if request != expected:
                        raise AssertionError(f"unexpected IPC request {request!r}, expected {expected!r}")
                    conn.sendall(json.dumps(response).encode() + b"\n")
        except Exception as exc:
            errors.append(exc)

    worker = threading.Thread(target=mock, daemon=True)
    worker.start()

    def call(identifier, method, params):
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                       "method": method, "params": params}) + "\n")
        server.stdin.flush()
        if not select.select([server.stdout], [], [], 10)[0]:
            raise RuntimeError("MCP response timeout")
        response = json.loads(server.stdout.readline())
        assert response["id"] == identifier, response
        return response["result"]

    result = call(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                     "clientInfo": {"name": "test", "version": "1"}})
    assert result["protocolVersion"] == "2025-03-26"
    server.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    server.stdin.flush()
    tools = call(2, "tools/list", {})["tools"]
    assert {t["name"] for t in tools} == {case[0] for case in valid}
    ident = 3
    for name, args in invalid:
        result = call(ident, "tools/call", {"name": name, "arguments": args})
        assert result.get("isError") is True, (name, args, result)
        ident += 1
    for name, args, expected_request, expected_response in valid:
        result = call(ident, "tools/call", {"name": name, "arguments": args})
        assert result.get("isError", False) == (not expected_response["ok"]), (name, result)
        expected_result = dict(expected_response)
        if "payload" in expected_result:
            expected_result["payload"] = json.loads(expected_result["payload"])
        assert json.loads(result["content"][0]["text"]) == expected_result, (name, result)
        ident += 1
    worker.join(timeout=10)
    assert not worker.is_alive()
    assert not errors, errors
    assert received == [case[2] for case in valid], received
    listener.close()
    os.unlink(path + "/control.sock")
    unavailable = call(ident, "tools/call", {"name": "keep_awake_status", "arguments": {}})
    assert unavailable["isError"] is True
    print("MCP stdio and isolated IPC integration passed")
finally:
    server.stdin.close()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    if os.path.exists(path + "/control.sock"):
        os.unlink(path + "/control.sock")
    if os.path.isdir(path):
        os.rmdir(path)
