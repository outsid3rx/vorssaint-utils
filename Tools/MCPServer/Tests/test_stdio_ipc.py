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
try:
    os.mkdir(path, 0o700)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path + "/control.sock")
    listener.listen(3)
    listener.settimeout(10)

    def mock():
        for expected in ("status", "start", "stop"):
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
                response = {"ok": True, "available": True, "active": expected == "start"}
                conn.sendall(json.dumps(response).encode() + b"\n")

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
    assert {t["name"] for t in tools} == {"keep_awake_status", "keep_awake_start", "keep_awake_stop"}
    invalid = call(3, "tools/call", {"name": "keep_awake_start", "arguments": {"minutes": 7}})
    assert invalid["isError"] is True
    for ident, name, args, active in [(4, "keep_awake_status", {}, False),
                                      (5, "keep_awake_start", {"minutes": 15}, True),
                                      (6, "keep_awake_stop", {}, False)]:
        result = call(ident, "tools/call", {"name": name, "arguments": args})
        assert result["isError"] is False, result
        state = json.loads(result["content"][0]["text"])
        assert state["active"] is active and state["available"] is True
    worker.join(timeout=10)
    assert not worker.is_alive()
    assert received == [{"command": "status"}, {"command": "start", "minutes": 15},
                        {"command": "stop"}], received
    listener.close()
    os.unlink(path + "/control.sock")
    unavailable = call(7, "tools/call", {"name": "keep_awake_status", "arguments": {}})
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
