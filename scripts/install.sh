#!/usr/bin/env bash
# Builds Glassforce.app and installs it into /Applications (or ~/Applications without write access),
# then launches it so first-run onboarding appears. A signed DMG replaces this in milestone 6.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x Glassforce 2>/dev/null || true
rm -rf "$DEST/Glassforce.app"
cp -R build/Glassforce.app "$DEST/Glassforce.app"
echo "Installed $DEST/Glassforce.app"

if [ "${1:-}" != "--no-launch" ]; then
  open "$DEST/Glassforce.app"
  echo "Launched. Glassforce does not open a window on its own. Click the bolt in the menu bar and choose Search Salesforce (or press Option-Space)."
fi
