#!/usr/bin/env bash
# Installs the official reference MCP servers used by sherpa_mcp's
# integration tests into a directory OUTSIDE the repo (their code is run
# by tests only, never shipped).
#
#   packages/sherpa_mcp/tool/install_test_servers.sh [dir]
#
# Default dir: $SHERPA_MCP_TEST_SERVERS or /tmp/claude-0/mcp-test-servers.
set -euo pipefail
root="${1:-${SHERPA_MCP_TEST_SERVERS:-/tmp/claude-0/mcp-test-servers}}"
mkdir -p "$root/everything" "$root/modern"
cd "$root/everything"
[ -f package.json ] || echo '{"name":"everything-host","private":true,"type":"module"}' > package.json
npm install --no-audit --no-fund --ignore-scripts \
  @modelcontextprotocol/server-everything@1.0.0 @modelcontextprotocol/sdk@1.32.1
cd "$root/modern"
[ -f package.json ] || echo '{"name":"modern-host","private":true,"type":"module"}' > package.json
npm install --no-audit --no-fund --ignore-scripts \
  @modelcontextprotocol/server@2.3.1 @modelcontextprotocol/core@2.3.1 zod@4.6.7
echo "installed into $root"
