# Contributing

Build Glassforce from `main`. Keep the privacy rules on every change.

Product behavior is in the [README](README.md). The module split is in [Architecture](ARCHITECTURE.md).

## Build the app

You need macOS 26. You also need Xcode 26 or the Swift 6.2 command line tools.

Run these commands in order.

```sh
git clone https://github.com/srikolagani/glassforce.git
cd glassforce
swift build
scripts/test.sh
scripts/build-app.sh
open build/Glassforce.app
```

Press Option-Space.

No CI builds the app yet. Run the commands on a Mac. The packaged public client id ships in source; no env file is required to connect (see the README).

## If SwiftPM rejects the manifest

Some Command Line Tools installs ship stale `*.private.swiftinterface` files beside `PackageDescription`. Every manifest then fails. The errors include `reference to member 'v26'` and `undefined symbol Package.__allocating_init`.

Reinstall the Command Line Tools, or install Xcode.

To work around it without sudo, point SwiftPM at a cleaned copy, then run the build again.

```sh
PM=~/Library/Caches/glassforce-swiftpm
mkdir -p "$PM"
cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI "$PM"/
cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI "$PM"/
find "$PM" -name '*.private.swiftinterface' -delete
export SWIFTPM_CUSTOM_LIBS_DIR="$PM"
```

## Privacy rules

Follow these rules in every change.

- Do not add telemetry, analytics, or crash reporting.
- Do not add a third-party SDK.
- Send network traffic only to the signed-in user's Salesforce org. The mock Salesforce flag may talk to `127.0.0.1`.
- Keep OAuth tokens in the Keychain. Do not write tokens to disk, to logs, or to `UserDefaults`.

## License

Glassforce is MIT. The terms are in [LICENSE](LICENSE). Do not copy code that carries a license incompatible with MIT. Leave GPL code and AGPL code out. Ideas from other projects are fine.

## Secrets

Do not commit a refresh token, access token, certificate, or a `.env` file with secrets. There is no client secret: Glassforce is a public OAuth client protected by PKCE.

The one exception is `PackagedApp.shippedConsumerKey`: that value is the packaged External Client App's **public** client id. It is safe to commit. Overrides for packaging experiments still live in the gitignored `config/glassforce.local.env`.

Source builds that should connect need no env file. See the [README](README.md).

Use sample org data in screenshots. Do not commit a customer's records.

## Tests

When you change logic in `GlassforceCore`, add or update a swift-testing test. Run `scripts/test.sh` on a Mac. GitHub does not run that script.

## Pull requests

Keep each pull request to one change. Run `swift build` and `scripts/test.sh` before you ask for review. Attach screenshots when the UI changes. Use the pull request template.

## Reports

Use the issue templates. Do not paste tokens or org data into an issue. For a vulnerability, follow [Security](SECURITY.md) and do not file a public issue. Behavior in the project is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
