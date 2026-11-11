# Glassforce

Glassforce is a native macOS 26 command bar for Salesforce. Press **Option–Space** from any app, search your org, and open a record in Lightning. The panel uses the system Liquid Glass material.

See the [Glassforce website](https://glassforce-preview.breezy-otter-7121.chatgpt.site/) for an overview. This repository contains the sanitized source snapshot and synthetic fixtures.

## What the app does

- **Fast search:** prefix, acronym, and typo matching over a local SQLite FTS cache. Arrow keys move through results; Return opens the selected record in Lightning.
- **Record actions:** the selected row has an inline preview. Use **⌘K** for Open and Copy Link. **⌘C** copies the selected record link when the search field has no text selection.
- **Confirmed update:** a supported opportunity stage change shows the exact change before anything is sent. The app writes only after you click Confirm.
- **Object selection:** Settings lists eligible standard and custom objects from your org. Select which objects to sync and search.
- **Org connection:** an admin installs the Glassforce package once per Salesforce org. Each user then signs in using OAuth with PKCE and confirms the org shown by the app.

## Install status

There is no published download and no Homebrew tap yet. This source is a release candidate, not a supported binary release. Native tests use mocks and synthetic data; they do not certify package installation or Salesforce writes in your org.

The current source can be built locally on macOS 26 with Xcode 26 or the Swift 6.2 Command Line Tools:

```sh
git clone https://github.com/srikolagani/glassforce-public.git
cd glassforce-public
GLASSFORCE_SIGN_IDENTITY=- scripts/build-app.sh release
open build/Glassforce.app
```

The first build can take a few minutes. This command builds an ad-hoc signed app without creating a certificate, changing Keychain settings, or replacing an installed app. macOS may require approval in **System Settings → Privacy & Security → Open Anyway**. Leave Gatekeeper and quarantine enabled.

To move a window, drag the search icon in the command bar or the top edge of the setup card. Text fields and action buttons keep their normal click behavior.

If SwiftPM reports `reference to member 'v26'` or `undefined symbol Package.__allocating_init`, the Command Line Tools may have stale private interface files. Reinstall the tools, or use the documented temporary workaround:

```sh
PM="$HOME/Library/Caches/glassforce-swiftpm"
mkdir -p "$PM"
cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI "$PM"/
find "$PM" -name '*.private.swiftinterface' -delete
export SWIFTPM_CUSTOM_LIBS_DIR="$PM"
GLASSFORCE_SIGN_IDENTITY=- scripts/build-app.sh release
```

## Connect your org

1. Press **Option–Space** or choose **Search Salesforce** from the menu bar, then choose **Get Started**.
2. Choose Production, Sandbox, or your Salesforce My Domain. An admin installs the Glassforce package; if it is already installed, choose **Skip**.
3. Choose **Connect**, sign in to Salesforce, and click **Allow**.
4. Check the org name, username, and instance host. Choose **Use this org** to save the OAuth sign-in in Keychain and start syncing. Choose **Sign in to a different org** if the card is wrong.
5. When sync finishes, search with **Option–Space**. Use the gear in the panel or **⌘,** to change searchable objects.

## Privacy

- Refresh tokens are stored in this device’s macOS Keychain, not in iCloud Keychain. Access tokens stay in memory.
- Synced record fields are stored locally in SQLite and JSON under `~/Library/Application Support/Glassforce`. This cache is not application-encrypted and may contain sensitive org data. Tokens are not stored with records.
- Normal sign-in, sync, and update flows use Salesforce endpoints. The app trusts Salesforce token responses for instance and identity URLs; automatic HTTP redirects are refused. Glassforce does not collect your Salesforce password or MFA codes.
- The app has no telemetry, analytics, crash reporting, or third-party SDKs.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details and [SECURITY.md](SECURITY.md) for security reporting.

## Verification and packaging

```sh
scripts/test.sh
scripts/release.sh
```

Release packaging requires a clean Git checkout. It produces an ad-hoc signed DMG, checksums, and generated casks in `build/release` without publishing or changing tracked source. The DMG has an Applications shortcut; drag Glassforce into Applications to install. No Developer ID signature or notarization is implied.

Before public distribution, verify the packaged app on a clean Mac and complete an authorized Salesforce sandbox sign-in and sync. A stage update uses the local cached before-value, not server-side optimistic concurrency: another user’s later change can be overwritten. Do not rely on it to detect server conflicts.

## License

[MIT](LICENSE). Copyright 2026 Sri Kolagani. Glassforce is independent software and is not affiliated with, sponsored by, or endorsed by Salesforce, Inc. Salesforce is a trademark of Salesforce, Inc.
