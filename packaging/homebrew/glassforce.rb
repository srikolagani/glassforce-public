# frozen_string_literal: true

# Personal tap cask for github.com/srikolagani/homebrew-tap (srikolagani/tap).
# Not for homebrew/cask. Not published. The app is ad-hoc signed unless a
# Developer ID was supplied via GLASSFORCE_SIGN_IDENTITY.
# Do not install with --no-quarantine. An ad-hoc app is approved by the user
# in System Settings > Privacy & Security > Open Anyway.
# Template only: not installable. Use build/release/glassforce.rb after packaging.
cask "glassforce" do
  version "0.1.0"
  sha256 "GENERATED_BY_SCRIPTS_RELEASE_SH"

  url "https://github.com/srikolagani/glassforce-public/releases/download/v0.1.0/Glassforce-0.1.0.dmg"
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
