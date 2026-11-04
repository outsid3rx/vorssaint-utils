#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-ipc-test.XXXXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/cache" -D VORSSAINT_MCP_TEST \
  "$ROOT/Sources/Vorssaint/Services/MCP/MCPIPC.swift" \
  "$ROOT/Tools/MCPServer/Tests/IPC/main.swift" -o "$TEST_DIR/ipc-test"
"$TEST_DIR/ipc-test"
swiftc -module-cache-path "$TEST_DIR/cache" -D VORSSAINT_MCP_TEST \
  "$ROOT/Sources/Vorssaint/Services/MCP/MCPIPC.swift" \
  "$ROOT/Tools/MCPServer/Tests/IPCDeadline/main.swift" -o "$TEST_DIR/deadline-test"
"$TEST_DIR/deadline-test"
