#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-mcp-stdio.XXXXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swift build --package-path "$ROOT/Tools/MCPServer" --scratch-path "$TEST_DIR/build" \
  -c release --product VorssaintMCP --force-resolved-versions \
  -Xswiftc -swift-version -Xswiftc 5 -Xswiftc -DVORSSAINT_MCP_TEST
python3 "$ROOT/Tools/MCPServer/Tests/test_stdio_ipc.py" "$TEST_DIR/build/release/VorssaintMCP"
