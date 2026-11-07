# frozen_string_literal: true

# Personal tap cask for github.com/srikolagani/homebrew-tap (srikolagani/tap).
# Not for homebrew/cask. Not published. The app is ad-hoc signed unless a
# Developer ID was supplied via GLASSFORCE_SIGN_IDENTITY.
# Do not install with --no-quarantine. An ad-hoc app is approved by the user
# in System Settings > Privacy & Security > Open Anyway.
# Filled by scripts/release.sh. This script does not publish the tap or a release.
cask "glassforce" do
  version "0.1.0"
  sha256 "5df42cfa748f21887fd5e449270b96e3744f231dd8c66fc8356590c513051cdc"

  url "https://github.com/srikolagani/glassforce/releases/download/v0.1.0/Glassforce-0.1.0.dmg"
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
