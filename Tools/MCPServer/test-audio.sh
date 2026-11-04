#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vorssaint-mcp-audio-test.XXXXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/cache" \
  "$ROOT/Sources/Vorssaint/Services/MCP/MCPIPC.swift" \
  "$ROOT/Sources/Vorssaint/Services/MCP/MCPAudioPolicy.swift" \
  "$ROOT/Sources/Vorssaint/Services/MCP/MCPAudioAdapter.swift" \
  "$ROOT/Tools/MCPServer/Tests/AudioAdapter/main.swift" -o "$TEST_DIR/audio-test"
"$TEST_DIR/audio-test"
