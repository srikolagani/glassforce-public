# Architecture

Glassforce is an accessory Mac app (no Dock icon). Option-Space opens a glass panel that searches a local cache of one Salesforce org.

## Targets

- `Sources/Glassforce`: the app. Panel, hotkey, onboarding, settings, Keychain adapter, SwiftUI views.
- `Sources/GlassforceCore`: everything without a window. Auth, sync, search, record links, the mock Salesforce. Tests import this target.

## Panel and hotkey

The hotkey is Carbon `RegisterEventHotKey` for Option-Space, so it needs no Accessibility permission. The panel uses SwiftUI `.glassEffect(.regular)` and follows the system appearance. `PanelController` owns the window; `CommandBarModel` owns the query, results and selection.

## Auth

- **Package.** An unlocked package carries a Packaged External Client App (`scripts/package-eca.sh`, `scripts/package-eca.md`). The app lives in the Dev Hub; every org that installs the package shares its one public consumer key.
- **Install.** Onboarding opens `<login host>/packaging/installPackage.apexp?p0=<04t>` for Production, Sandbox or a My Domain (`PackagedApp.installURL`).
- **Sign-in.** OAuth 2.0 authorization code with PKCE in `ASWebAuthenticationSession`. Callback `dev.glassforce.app://oauth/callback`, scopes `api refresh_token id`. No client secret.
- **Tokens.** Keychain service `dev.glassforce.oauth`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. `TokenManager` refreshes on expiry.
- **Config.** The packaged consumer key and 04t come from `config/glassforce.local.env` (gitignored), which `scripts/build-app.sh` copies into Info.plist; `GLASSFORCE_PACKAGED_CONSUMER_KEY` and `GLASSFORCE_PACKAGE_VERSION_ID` env vars override Info.plist. For a bring-your-own app, a key typed under Advanced on the Connect step (kept in `UserDefaults`) wins, then `GLASSFORCE_CONSUMER_KEY`, then the packaged key (`OAuthConfig.resolve`).

## Sync

`Sync/SyncPlan.swift` and `Auth/SalesforceClient.swift`.

- The object list comes from `describeGlobal`, filtered to layoutable objects (`Sync/ObjectCatalog.swift`). The selection is saved per org id.
- Each object is read newest first over REST, following `nextRecordsUrl`, up to 50,000 rows (`SyncPlan.defaultCap`).
- Later syncs are incremental by `LastModifiedDate`, with a full read once a day.
- Reports and a set of Setup pages are built in.
- Results are cached in `~/Library/Application Support/Glassforce`: an FTS5 file per org (`fts-*.sqlite`) plus the JSON copy, `syncstate-*.json`, and `orgs.json`. No tokens there. The file is opened only for the org id that has Keychain credentials.

## Search

`FuzzyMatcher.swift`, over rows stored in a per-org SQLite FTS5 file (`fts-<org>.sqlite`). FTS5 answers prefix lookups; typos and acronyms are ranked in memory by `FuzzyMatcher` because FTS5 would drop them. The panel shows at most 80 rows. Return opens the Lightning page. Cmd-C copies the record link when the search field has no selection. `scripts/bench.sh` runs the 10k-record benchmark on an optimized build (budget p95 < 50 ms).

## Opening records

`RecordOpener.swift` and `Auth/LightningHost.swift`. The Lightning host is derived from the My Domain host (`x.my.salesforce.com` → `x.lightning.force.com`, with the sandbox and Developer Edition partitions). Records open at `/lightning/r/<Object>/<Id>/view`, Setup pages at `/lightning/setup/<Page>/home`. Click and Return share one path.

## Development flags

`--mock-salesforce` runs the whole flow against a fake Salesforce on `127.0.0.1` (`Mock/`). `--show-panel`, `--query`, `--pin`, `--onboarding`, `--open-settings` and `--diagnose-sync` help with screenshots and debugging. See `LaunchOptions.swift`.
