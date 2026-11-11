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

# Validate before invoking the builder: neither an empty identity nor codesign's
# literal '-' is a Developer ID that can be notarized.
SIGN_IDENTITY="${GLASSFORCE_SIGN_IDENTITY:--}"
if [[ -n "${GLASSFORCE_NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "error: notarization needs GLASSFORCE_SIGN_IDENTITY (a Developer ID, not ad-hoc '-')." >&2
  exit 1
fi

# A release must identify one committed snapshot, without local identity overrides.
if ! git rev-parse --verify HEAD >/dev/null 2>&1 || [[ -n "$(git status --porcelain)" ]]; then
  echo "error: release packaging requires a clean Git checkout." >&2
  exit 1
fi
if [[ -f config/glassforce.local.env || -n "${GLASSFORCE_PACKAGED_CONSUMER_KEY:-}" || -n "${GLASSFORCE_PACKAGE_VERSION_ID:-}" ]]; then
  echo "error: release packaging refuses local packaged-app identity overrides." >&2
  exit 1
fi
SOURCE_SHA="$(git rev-parse HEAD)"

echo "==> Building Release .app (version $VERSION, build $BUILD_NUMBER)"
# Override the development builder's automatic identity discovery for releases.
# The default release must not unlock or use a developer's signing keychain.
GLASSFORCE_SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh release
mkdir -p "$DIST"
rm -rf "$DIST/${APP_NAME}.app"
cp -R "build/${APP_NAME}.app" "$DIST/${APP_NAME}.app"

BUNDLE_ID="com.srikolagani.glassforce"
APP_PATH="$DIST/${APP_NAME}.app"
# Default is ad-hoc. A Developer ID in the keychain is not picked up on its own.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
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

codesign --verify --strict --verbose=2 "$APP_PATH"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print GlassforceSourceSHA' "$APP_PATH/Contents/Info.plist")" != "$SOURCE_SHA" ||
      "$(/usr/libexec/PlistBuddy -c 'Print GlassforceSourceDirty' "$APP_PATH/Contents/Info.plist")" != "false" ||
      "$(git rev-parse HEAD)" != "$SOURCE_SHA" || -n "$(git status --porcelain)" ]]; then
  echo "error: source changed while packaging; refusing release artifacts." >&2
  exit 1
fi

echo "==> Creating DMG $DIST/$DMG_NAME"
rm -f "$DIST/$DMG_NAME"
STAGE="$(mktemp -d "$DIST/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DIST/$DMG_NAME" >/dev/null
SHA="$(shasum -a 256 "$DIST/$DMG_NAME" | awk '{print $1}')"
echo "    sha256 $SHA"

RELEASE_URL="https://github.com/srikolagani/glassforce-public/releases/download/v${VERSION}/${DMG_NAME}"
LOCAL_URL="file://$(cd "$DIST" && pwd)/${DMG_NAME}"
export VERSION SHA RELEASE_URL LOCAL_URL SOURCE_SHA SIGNING_STATUS NOTARY_STATUS
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
# Generated in build/release by scripts/release.sh. Not published.
cask "glassforce" do
  version "{version}"
  sha256 "{sha}"

  url "{url}"
  name "Glassforce"
  desc "Native macOS command bar for Salesforce"
  homepage "https://github.com/srikolagani/glassforce-public"

  depends_on macos: :tahoe

  app "Glassforce.app"

  zap trash: [
    "~/Library/Application Support/Glassforce",
    "~/Library/Logs/Glassforce",
    "~/Library/Preferences/com.srikolagani.glassforce.plist",
  ]
end
"""
Path("build/release/glassforce.rb").write_text(body)
Path("build/release/glassforce.local.rb").write_text(body.replace(url, local_url))
import json
Path("build/release/SHA256SUMS").write_text(f"{sha}  Glassforce-{version}.dmg\n")
Path("build/release/release-metadata.json").write_text(json.dumps({
    "version": version, "source_sha": os.environ["SOURCE_SHA"], "source_dirty": False,
    "dmg_sha256": sha, "signing": os.environ["SIGNING_STATUS"],
    "notarization": os.environ["NOTARY_STATUS"], "published": False,
}, indent=2) + "\n")
print("Generated casks, checksums and release metadata in build/release")
PY

cat <<SUMMARY

==> Release packaging summary
app:        $DIST/${APP_NAME}.app
dmg:        $DIST/$DMG_NAME
sha256:     $SHA
signing:    $SIGNING_STATUS
notarize:   $NOTARY_STATUS
cask:       build/release/glassforce.rb (srikolagani/tap, not homebrew/cask)
local cask: build/release/glassforce.local.rb (file:// for a local brew check)

Ad-hoc DMG is a local candidate, not a notarized release. Set GLASSFORCE_SIGN_IDENTITY and
GLASSFORCE_NOTARY_PROFILE only when you want Developer ID and notarization.
This script does not create a GitHub release or push the tap.
SUMMARY
