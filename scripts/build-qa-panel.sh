#!/usr/bin/env bash
# Assemble GlassforcePanelQA.app and ad-hoc sign the bundle. Does not launch it.
# Strict codesign verify checks the sealed bundle. It is not a Gatekeeper acceptance.
# The bundle id is com.srikolagani.glassforce.qa, not the installed app's id.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
swift build --product GlassforcePanelQA -c debug
BIN_DIR="$(swift build --product GlassforcePanelQA --show-bin-path)"

# Same git facts as scripts/build-app.sh. Do not invent a commit.
PROVENANCE="$(bash scripts/source-provenance.sh "$PWD")"
SOURCE_SHA="$(printf '%s\n' "$PROVENANCE" | awk '$1=="GlassforceSourceSHA"{print $2}')"
SOURCE_DIRTY="$(printf '%s\n' "$PROVENANCE" | awk '$1=="GlassforceSourceDirty"{print $2}')"
if [[ -z "${SOURCE_DIRTY}" ]]; then SOURCE_DIRTY="unknown"; fi
echo "Source: sha=${SOURCE_SHA:-<none>} dirty=${SOURCE_DIRTY}"

APP="build/GlassforcePanelQA.app"
BUNDLE_ID="com.srikolagani.glassforce.qa"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GlassforcePanelQA" "$APP/Contents/MacOS/GlassforcePanelQA"
# The Swift linker ad-hoc signature is for a bare executable. Remove it before
# the bundle is sealed, or strict verify says resources must be present and are not.
codesign --remove-signature "$APP/Contents/MacOS/GlassforcePanelQA"

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Info.plist is written before signing so the seal binds it.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GlassforcePanelQA</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Glassforce QA</string>
  <key>CFBundleDisplayName</key><string>Glassforce QA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GlassforceSourceSHA</key><string>${SOURCE_SHA}</string>
  <key>GlassforceSourceDirty</key><string>${SOURCE_DIRTY}</string>
</dict>
</plist>
PLIST

# Seal the .app, not the inner binary. This writes Contents/_CodeSignature/CodeResources
# and binds Info.plist. Strict verify is the script gate. It checks the sealed
# bundle only. It does not ask the system to accept an ad-hoc app.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP/Contents/Info.plist" >/dev/null
fi

printf '%s\n' "Built $APP ($VERSION, build $BUILD_NUMBER)"
printf '%s\n' "Strict bundle verify passed. That is integrity, not Gatekeeper acceptance."
printf '%s\n' "Does not launch. After the safety, build, and OS gates pass, invoke:"
printf '%s\n' "  $APP/Contents/MacOS/GlassforcePanelQA --qa-root /tmp/gf-panel-qa"
printf '%s\n' "The panel opens on screen. Type, use the arrow keys, and look at the preview."
printf '%s\n' "The badge says Localhost · 127.0.0.1 fixtures. This script does not record."
