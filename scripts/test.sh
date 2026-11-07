#!/usr/bin/env bash
# Runs the swift-testing suite. On Command Line Tools-only setups (no Xcode), SwiftPM can
# intermittently fail to find the TestingMacros plugin on clean builds; pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
  [ -d "$PLUGINS" ] && ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi
exec swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
