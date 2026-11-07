#!/usr/bin/env bash
# Build a Release .app, ad-hoc sign it, and wrap a DMG.
# Developer ID signing and notarization run only when their env vars are set.
# Neither is required. Never publishes: no gh release, no tap push, no App Store submit.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="build/release"
APP_NAME="Glassforce"
DMG_NAME="Glassforce-${VERSION}.dmg"

echo "==> Building Release .app (version $VERSION, build $BUILD_NUMBER)"
scripts/build-app.sh release
mkdir -p "$DIST"
rm -rf "$DIST/${APP_NAME}.app"
cp -R "build/${APP_NAME}.app" "$DIST/${APP_NAME}.app"

BUNDLE_ID="com.srikolagani.glassforce"
APP_PATH="$DIST/${APP_NAME}.app"
# Default is ad-hoc. A Developer ID in the keychain is not picked up on its own.
if [[ -n "${GLASSFORCE_SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with GLASSFORCE_SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$GLASSFORCE_SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" "$APP_PATH"
  SIGNING_STATUS="Developer ID: $GLASSFORCE_SIGN_IDENTITY"
else
  echo "==> Ad-hoc signature (Developer ID not required)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_PATH"
  SIGNING_STATUS="ad-hoc"
fi

NOTARY_STATUS="not requested"
if [[ -n "${GLASSFORCE_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${GLASSFORCE_SIGN_IDENTITY:-}" ]]; then
    echo "error: GLASSFORCE_NOTARY_PROFILE is set, but notarization needs GLASSFORCE_SIGN_IDENTITY." >&2
    echo "Unset GLASSFORCE_NOTARY_PROFILE to build the ad-hoc DMG." >&2
    exit 1
  fi
  echo "==> Notarizing with notarytool profile \"$GLASSFORCE_NOTARY_PROFILE\""
  ditto -c -k --keepParent "$APP_PATH" "$DIST/${APP_NAME}.zip"
  xcrun notarytool submit "$DIST/${APP_NAME}.zip" \
    --keychain-profile "$GLASSFORCE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  NOTARY_STATUS="notarized + stapled (profile $GLASSFORCE_NOTARY_PROFILE)"
  rm -f "$DIST/${APP_NAME}.zip"
else
  echo "==> Notarization skipped (optional)"
fi

echo "==> Creating DMG $DIST/$DMG_NAME"
rm -f "$DIST/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DIST/${APP_NAME}.app" \
  -ov -format UDZO "$DIST/$DMG_NAME" >/dev/null
SHA="$(shasum -a 256 "$DIST/$DMG_NAME" | awk '{print $1}')"
echo "    sha256 $SHA"

RELEASE_URL="https://github.com/srikolagani/glassforce/releases/download/v${VERSION}/${DMG_NAME}"
LOCAL_URL="file://$(cd "$DIST" && pwd)/${DMG_NAME}"
export VERSION SHA RELEASE_URL LOCAL_URL
python3 - <<'PY'
from pathlib import Path
import os
version = os.environ["VERSION"]
sha = os.environ["SHA"]
url = os.environ["RELEASE_URL"]
local_url = os.environ["LOCAL_URL"]
body = f"""# frozen_string_literal: true

# Personal tap cask for github.com/srikolagani/homebrew-tap (srikolagani/tap).
# Not for homebrew/cask. Not published. The app is ad-hoc signed unless a
# Developer ID was supplied via GLASSFORCE_SIGN_IDENTITY.
# Do not install with --no-quarantine. An ad-hoc app is approved by the user
# in System Settings > Privacy & Security > Open Anyway.
# Filled by scripts/release.sh. This script does not publish the tap or a release.
cask "glassforce" do
  version "{version}"
  sha256 "{sha}"

  url "{url}"
  name "Glassforce"
  desc "Native macOS command bar for Salesforce"
  homepage "https://github.com/srikolagani/glassforce"

  depends_on macos: :tahoe

  app "Glassforce.app"

  zap trash: [
    "~/Library/Application Support/Glassforce",
    "~/Library/Logs/Glassforce",
    "~/Library/Preferences/com.srikolagani.glassforce.plist",
  ]
end
"""
Path("packaging/homebrew/glassforce.rb").write_text(body)
Path("build/release/glassforce.local.rb").write_text(body.replace(url, local_url))
print("Updated packaging/homebrew/glassforce.rb and build/release/glassforce.local.rb")
PY

cat <<SUMMARY

==> Release packaging summary
app:        $DIST/${APP_NAME}.app
dmg:        $DIST/$DMG_NAME
sha256:     $SHA
signing:    $SIGNING_STATUS
notarize:   $NOTARY_STATUS
cask:       packaging/homebrew/glassforce.rb (srikolagani/tap, not homebrew/cask)
local cask: build/release/glassforce.local.rb (file:// for a local brew check)

Ad-hoc DMG is the ship build. Set GLASSFORCE_SIGN_IDENTITY and
GLASSFORCE_NOTARY_PROFILE only when you want Developer ID and notarization.
This script does not create a GitHub release or push the tap.
SUMMARY
