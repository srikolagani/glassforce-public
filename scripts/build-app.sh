#!/usr/bin/env bash
# Wraps the SwiftPM executable into Glassforce.app (accessory app, no Dock icon).
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
swift build -c "$CONFIG" --product Glassforce
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Packaged-app identity comes from config/glassforce.local.env (written by scripts/package-eca.sh, gitignored).
GLASSFORCE_PACKAGED_CONSUMER_KEY="${GLASSFORCE_PACKAGED_CONSUMER_KEY:-}"
GLASSFORCE_PACKAGE_VERSION_ID="${GLASSFORCE_PACKAGE_VERSION_ID:-}"
if [[ -f config/glassforce.local.env ]]; then
  # shellcheck disable=SC1091
  set -a; . config/glassforce.local.env; set +a
fi
# Always embed real values in Info.plist. Read shipped defaults from PackagedApp.swift so
# gitleaks (no config) does not flag a duplicated public client id literal in this script.
PACKAGED_APP_SWIFT="Sources/GlassforceCore/Auth/PackagedApp.swift"
SHIPPED_CONSUMER_KEY="$(sed -nE 's/.*shippedConsumerKey = "([^"]+)".*/\1/p' "$PACKAGED_APP_SWIFT" | head -1)"
SHIPPED_PACKAGE_VERSION_ID="$(sed -nE 's/.*shippedPackageVersionID = "([^"]+)".*/\1/p' "$PACKAGED_APP_SWIFT" | head -1)"
if [[ -z "$SHIPPED_CONSUMER_KEY" || -z "$SHIPPED_PACKAGE_VERSION_ID" ]]; then
  echo "error: could not read PackagedApp.shipped* from $PACKAGED_APP_SWIFT" >&2
  exit 1
fi
if [[ -z "$GLASSFORCE_PACKAGED_CONSUMER_KEY" ]]; then
  GLASSFORCE_PACKAGED_CONSUMER_KEY="$SHIPPED_CONSUMER_KEY"
  echo "Packaged app: Info.plist consumer key ← PackagedApp.shippedConsumerKey"
fi
if [[ -z "$GLASSFORCE_PACKAGE_VERSION_ID" ]]; then
  GLASSFORCE_PACKAGE_VERSION_ID="$SHIPPED_PACKAGE_VERSION_ID"
  echo "Packaged app: Info.plist package version ← PackagedApp.shippedPackageVersionID"
fi
echo "Packaged app: Info.plist will carry version ${GLASSFORCE_PACKAGE_VERSION_ID}"

# Record the commit this build actually saw. Empty SHA means git did not answer;
# do not substitute a remembered or guessed commit. Does not rewrite existing apps.
PROVENANCE="$(bash scripts/source-provenance.sh "$PWD")"
SOURCE_SHA="$(printf '%s\n' "$PROVENANCE" | awk '$1=="GlassforceSourceSHA"{print $2}')"
SOURCE_DIRTY="$(printf '%s\n' "$PROVENANCE" | awk '$1=="GlassforceSourceDirty"{print $2}')"
if [[ -z "${SOURCE_DIRTY}" ]]; then SOURCE_DIRTY="unknown"; fi
echo "Source: sha=${SOURCE_SHA:-<none>} dirty=${SOURCE_DIRTY}"

APP="build/Glassforce.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Glassforce" "$APP/Contents/MacOS/Glassforce"

# App icon: rebuild the .icns from the iconset with iconutil when available, else use the checked-in .icns.
if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Glassforce</string>
    <key>CFBundleDisplayName</key><string>Glassforce</string>
    <key>CFBundleIdentifier</key><string>com.srikolagani.glassforce</string>
    <key>CFBundleExecutable</key><string>Glassforce</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Sri Kolagani. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>GlassforcePackagedConsumerKey</key><string>${GLASSFORCE_PACKAGED_CONSUMER_KEY}</string>
    <key>GlassforcePackageVersionID</key><string>${GLASSFORCE_PACKAGE_VERSION_ID}</string>
    <key>GlassforceBuildID</key><string>$(date +%Y%m%d%H%M%S)</string>
    <key>GlassforceSourceSHA</key><string>${SOURCE_SHA}</string>
    <key>GlassforceSourceDirty</key><string>${SOURCE_DIRTY}</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing: a stable identity keeps the designated requirement identical across rebuilds, so the
# Keychain's "Always Allow" for the saved sign-in sticks. Order: $GLASSFORCE_SIGN_IDENTITY, an Apple
# Development / Developer ID identity, the "Glassforce Local Dev" identity (scripts/dev-signing.sh),
# else ad-hoc (works, but macOS asks for Keychain access again after every rebuild).
BUNDLE_ID="com.srikolagani.glassforce"
IDENTITY="${GLASSFORCE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"((Apple Development|Developer ID Application): [^"]*)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" && -n "$(scripts/dev-signing.sh --keychain)" ]]; then
  scripts/dev-signing.sh --unlock
  IDENTITY="Glassforce Local Dev"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP" >/dev/null
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
  echo "Signed ad-hoc (run scripts/dev-signing.sh once to stop repeat Keychain prompts)"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
