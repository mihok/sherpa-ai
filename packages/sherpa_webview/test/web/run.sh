#!/usr/bin/env bash
# Chromium security suite for the MCP Apps shell page.
#
#   packages/sherpa_webview/test/web/run.sh            # all tests
#   packages/sherpa_webview/test/web/run.sh --test-name-pattern network
#
# Needs Node >= 20 and the `playwright` package (resolved from the global
# npm root unless PLAYWRIGHT_NODE_PATH is set) with a Chromium build in
# PLAYWRIGHT_BROWSERS_PATH (default /opt/pw-browsers). Never runs
# `playwright install`. The SDK compatibility test uses the vendored
# @modelcontextprotocol/ext-apps bundle (EXT_APPS_BUNDLE to override) and
# is skipped when it is absent.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"
export NODE_PATH="${PLAYWRIGHT_NODE_PATH:-$(npm root -g)}"
exec node --test --test-concurrency=1 "$@" "$here/security.test.mjs"
