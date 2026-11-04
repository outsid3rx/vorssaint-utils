#!/usr/bin/env python3
"""Exercise MCP stdio through an isolated mock IPC listener.

Build the server with -Xswiftc -DVORSSAINT_MCP_TEST first, then pass its path
as the sole argument. The test flag makes its socket path process-specific.
"""
import base64
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
request_id = "11111111-1111-4111-8111-111111111111"
recording_id = "ABCDEF12-2222-4222-8222-222222222222"
unknown_id = "33333333-3333-4333-8333-333333333333"
valid += [
    ("capture_start", {"mode": "screenshot"}, {"command": "capture_start", "action": "screenshot"}, {"ok": True, "payload": json.dumps({"id": request_id, "status": "selecting"})}),
    ("capture_start", {"mode": "text"}, {"command": "capture_start", "action": "text"}, {"ok": True}),
    ("capture_start", {"mode": "qr"}, {"command": "capture_start", "action": "qr"}, {"ok": True}),
    ("capture_status", {"id": request_id}, {"command": "capture_status", "id": request_id}, {"ok": True, "payload": json.dumps({"id": request_id, "mode": "screenshot", "status": "awaitingApproval"})}),
    ("capture_discard", {"id": request_id}, {"command": "capture_discard", "id": request_id}, {"ok": True}),
    ("recording_start", {}, {"command": "recording_start"}, {"ok": True}),
    ("recording_start", {"system_audio": True, "microphone": False}, {"command": "recording_start", "systemAudio": True, "microphone": False}, {"ok": True}),
    ("recording_status", {"id": recording_id}, {"command": "recording_status", "id": recording_id}, {"ok": True, "payload": json.dumps({"request_id": recording_id, "state": "recording"})}),
    ("recording_stop", {"id": recording_id}, {"command": "recording_stop", "id": recording_id}, {"ok": True}),
    ("recording_share", {"id": recording_id}, {"command": "recording_share", "id": recording_id}, {"ok": True, "payload": json.dumps({"request_id": recording_id, "export_state": "awaiting_approval"})}),
    ("recording_status", {"id": recording_id}, {"command": "recording_status", "id": recording_id}, {"ok": True, "payload": json.dumps({"request_id": recording_id, "export_state": "ready"})}),
    ("recording_set_paused", {"id": recording_id, "paused": True}, {"command": "recording_set_paused", "id": recording_id, "action": "pause"}, {"ok": True}),
    ("recording_set_paused", {"id": recording_id, "paused": False}, {"command": "recording_set_paused", "id": recording_id, "action": "resume"}, {"ok": True}),
    ("recording_stop", {"id": recording_id}, {"command": "recording_stop", "id": recording_id}, {"ok": False, "error": "not_found"}),
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
    ("capture_start", {}), ("capture_start", {"mode": "recording"}),
    ("capture_start", {"mode": "screenshot", "extra": 1}),
    ("capture_status", {}), ("capture_status", {"id": "not-a-uuid"}),
    ("capture_read", {"id": "not-a-uuid"}), ("capture_discard", {"id": request_id, "extra": 1}),
    ("recording_start", {"microphone": "true"}), ("recording_start", {"system_audio": 1}),
    ("recording_start", {"system_audio": True, "extra": 1}),
    ("recording_status", {}), ("recording_stop", {"id": "not-a-uuid"}),
    ("recording_share", {}), ("recording_share", {"id": "not-a-uuid"}),
    ("recording_share", {"id": request_id, "extra": 1}),
    ("recording_set_paused", {"id": request_id}),
    ("recording_set_paused", {"id": request_id, "paused": "false"}),
    ("recording_set_paused", {"id": request_id, "paused": True, "extra": 1}),
]

# A synthetic 1x1 PNG; this test never reads a screenshot or user data.
png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
text = "Тест OCR".encode("utf-8")

def frame(data, offset, mime, complete, *, total=None, next_offset=None):
    """Represent exactly one IPC chunk, including its two JSON layers."""
    end = offset + len(data)
    return {"ok": True, "payload": json.dumps({
        "id": request_id, "mime_type": mime, "offset": offset,
        "total_bytes": total if total is not None else end,
        "data_base64": base64.b64encode(data).decode("ascii"),
        "next_offset": next_offset, "complete": complete,
    })}

def read_request(offset):
    return {"command": "capture_read", "id": request_id, "offset": offset}

def changed(response, **fields):
    payload = json.loads(response["payload"])
    payload.update(fields)
    return {"ok": True, "payload": json.dumps(payload)}

split = len(png) // 2
text_split = 1  # split inside a UTF-8 code point
read_cases = [
    # kind, expected output, the precise IPC requests and responses
    ("image", png, [
        (read_request(0), frame(png[:split], 0, "image/png", False, total=len(png), next_offset=split)),
        (read_request(split), frame(png[split:], split, "image/png", True, total=len(png))),
    ]),
    ("text", text.decode("utf-8"), [
        (read_request(0), frame(text[:text_split], 0, "text/plain; charset=utf-8", False, total=len(text), next_offset=text_split)),
        (read_request(text_split), frame(text[text_split:], text_split, "text/plain; charset=utf-8", True, total=len(text))),
    ]),
    # A result that was consumed/discarded or denied must not return contents.
    ("error", None, [(read_request(0), {"ok": False, "error": "result_unavailable"})]),
    ("error", None, [(read_request(0), {"ok": False, "error": "denied"})]),
    # Reject out-of-sequence data without asking the app for another chunk.
    ("error", None, [(read_request(0), frame(b"x", 1, "image/png", True, total=2))]),
    ("error", None, [(read_request(0), frame(b"x", 0, "image/png", False, total=2, next_offset=2))]),
    ("error", None, [(read_request(0), frame(b"", 0, "image/png", False, total=2, next_offset=0))]),
    ("error", None, [(read_request(0), frame(b"x", 0, "image/png", True, total=2))]),
    ("error", None, [(read_request(0), frame(b"x", 0, "image/png", False, total=8 * 1024 * 1024 + 1, next_offset=1))]),
    ("error", None, [(read_request(0), frame(b"x" * 6145, 0, "image/png", True))]),
    ("error", None, [(read_request(0), changed(frame(b"x", 0, "image/png", True), data_base64="***"))]),
    ("error", None, [(read_request(0), changed(frame(b"x", 0, "image/png", True), id="22222222-2222-4222-8222-222222222222"))]),
    ("error", None, [(read_request(0), frame(b"\xff", 0, "text/plain; charset=utf-8", True))]),
    ("error", None, [
        (read_request(0), frame(b"x", 0, "image/png", False, total=2, next_offset=1)),
        (read_request(1), frame(b"y", 1, "text/plain; charset=utf-8", True, total=2)),
    ]),
    ("error", None, [
        (read_request(0), frame(b"x", 0, "image/png", False, total=2, next_offset=1)),
        (read_request(1), frame(b"y", 1, "image/png", True, total=3)),
    ]),
    # Authorization can be revoked while a multi-chunk read is in progress.
    ("error", None, [
        (read_request(0), frame(b"x", 0, "image/png", False, total=2, next_offset=1)),
        (read_request(1), {"ok": False, "error": "access_revoked"}),
    ]),
]
wire_events = [(expected, response) for _, _, expected, response in valid]
wire_events += [event for _, _, events in read_cases for event in events]

def recording_request(offset, id=recording_id):
    return {"command": "recording_read", "id": id, "offset": offset}

def recording_frame(data, offset, mime, complete, **kwargs):
    return changed(frame(data, offset, mime, complete, **kwargs), id=recording_id)

# A fabricated byte string, not a recording or personal data.
movie = b"\x00\x00\x00\x18ftypqt  synthetic-test-only"
movie_split = 8
recording_cases = [
    ("binary", recording_id.lower(), b"lowercase UUID", [
        (recording_request(0), recording_frame(b"lowercase UUID", 0, "video/quicktime", True)),
    ]),
    ("binary", recording_id, movie, [
        (recording_request(0), recording_frame(movie[:movie_split], 0, "video/quicktime", False, total=len(movie), next_offset=movie_split)),
        (recording_request(movie_split), recording_frame(movie[movie_split:], movie_split, "video/quicktime", True, total=len(movie))),
    ]),
    # A one-shot result cannot be read again, nor read without consent.
    ("error", recording_id, None, [(recording_request(0), {"ok": False, "error": "result_unavailable"})]),
    ("error", unknown_id, None, [(recording_request(0, unknown_id), {"ok": False, "error": "not_found"})]),
    ("error", recording_id, None, [(recording_request(0), {"ok": False, "error": "denied"})]),
    ("error", recording_id, None, [(recording_request(0), recording_frame(b"x", 1, "video/quicktime", True, total=2))]),
    ("error", recording_id, None, [(recording_request(0), recording_frame(b"x", 0, "video/quicktime", False, total=2, next_offset=2))]),
    ("error", recording_id, None, [(recording_request(0), recording_frame(b"x", 0, "video/quicktime", True, total=2))]),
    ("error", recording_id, None, [(recording_request(0), recording_frame(b"x", 0, "video/quicktime", False, total=32 * 1024 * 1024 + 1, next_offset=1))]),
    ("error", recording_id, None, [(recording_request(0), recording_frame(b"x", 0, "image/png", True))]),
    ("error", recording_id, None, [(recording_request(0), changed(recording_frame(b"x", 0, "video/quicktime", True), data_base64="***"))]),
    ("error", recording_id, None, [(recording_request(0), changed(recording_frame(b"x", 0, "video/quicktime", True), id=unknown_id))]),
    ("error", recording_id, None, [
        (recording_request(0), recording_frame(b"x", 0, "video/quicktime", False, total=2, next_offset=1)),
        (recording_request(1), {"ok": False, "error": "access_revoked"}),
    ]),
]
wire_events += [event for _, _, _, events in recording_cases for event in events]
try:
    os.mkdir(path, 0o700)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path + "/control.sock")
    listener.listen(3)
    listener.settimeout(10)
    errors = []

    def mock():
        try:
            for expected, response in wire_events:
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

    def rpc(identifier, method, params):
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                       "method": method, "params": params}) + "\n")
        server.stdin.flush()
        if not select.select([server.stdout], [], [], 10)[0]:
            raise RuntimeError("MCP response timeout")
        response = json.loads(server.stdout.readline())
        assert response["id"] == identifier, response
        return response

    def call(identifier, method, params):
        return rpc(identifier, method, params)["result"]

    result = call(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                     "clientInfo": {"name": "test", "version": "1"}})
    assert result["protocolVersion"] == "2025-03-26"
    server.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    server.stdin.flush()
    tools = call(2, "tools/list", {})["tools"]
    assert {t["name"] for t in tools} == {case[0] for case in valid} | {"capture_read"}
    assert len(tools) == 22, len(tools)
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
    for kind, expected, _ in read_cases:
        result = call(ident, "tools/call", {"name": "capture_read", "arguments": {"id": request_id}})
        if kind == "image":
            assert result.get("isError", False) is False, result
            content = result["content"][0]
            assert content["type"] == "image" and content["mimeType"] == "image/png", content
            assert base64.b64decode(content["data"]) == expected
        elif kind == "text":
            assert result.get("isError", False) is False, result
            assert result["content"] == [{"type": "text", "text": expected}], result
        else:
            assert result.get("isError") is True, result
        ident += 1
    assert call(ident, "resources/list", {})["resources"] == []
    ident += 1
    templates = call(ident, "resources/templates/list", {})["resourceTemplates"]
    assert any(t["uriTemplate"] == "vorssaint://recording/{id}" for t in templates), templates
    ident += 1
    for uri in ["file:///etc/passwd", "vorssaint://recording/not-a-uuid",
                f"vorssaint://recording/{request_id}?x=1", f"vorssaint://recording/{request_id}/extra"]:
        assert "error" in rpc(ident, "resources/read", {"uri": uri}), uri
        ident += 1
    for kind, resource_id, expected, _ in recording_cases:
        uri = f"vorssaint://recording/{resource_id}"
        reply = rpc(ident, "resources/read", {"uri": uri})
        if kind == "binary":
            content = reply["result"]["contents"][0]
            assert content["uri"] == uri and content["mimeType"] == "video/quicktime", content
            assert base64.b64decode(content["blob"]) == expected
        else:
            assert "error" in reply, reply
        ident += 1
    worker.join(timeout=10)
    assert not worker.is_alive()
    assert not errors, errors
    assert received == [event[0] for event in wire_events], received
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
