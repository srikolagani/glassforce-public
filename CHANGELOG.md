# Changelog

All notable changes to Glassforce are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Search and onboarding windows explicitly activate on user input; dedicated drag handles avoid consuming form clicks.
- Duplicate confirmations send one update, and a successful write refreshes the cache.
- Release packaging requires a clean commit and writes generated casks only to build output.
- HTTP requests refuse automatic redirects.

### Added
- Glassforce app icon (glass lightning shard on deep indigo) as an `AppIcon.iconset` and `.icns`, wired into `Glassforce.app`.
- Wordmark, colour palette, hero art and a brand guide (`docs/brand.md`).
- First-run onboarding window: welcome, ⌥ Space hint, Production / Sandbox / Custom Domain choice cards, connect, sync progress, done.
- Salesforce sign-in with OAuth 2.0 authorization code + PKCE (S256) through `ASWebAuthenticationSession`; callback `dev.glassforce.app://oauth/callback`, scopes `api refresh_token id`, no client secret.
- Refresh tokens stored only in the login Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced); silent, single-flight refresh per org with rotation; `invalid_grant` marks the org **Needs sign-in**.
- Multiple orgs with PROD / SANDBOX / DEV badges and a default org; local search index per org.
- Bring-your-own consumer key (Advanced field or `GLASSFORCE_CONSUMER_KEY`).
- `--mock-salesforce` local fake OAuth server and REST API, and `--demo-walkthrough` for recordings.
- `scripts/install.sh` to build and install into `/Applications`.

### Changed
- With no org connected, search is empty; `--fake-data` brings back the built-in fake records.

## [0.1.0] - 2026-11-03

Milestone 1: the command bar skeleton.

### Added
- Accessory (no Dock icon) macOS 26 app with a global **⌥ Space** hot key (Carbon `RegisterEventHotKey`, no Accessibility permission needed).
- Floating, borderless Spotlight-style panel near the top centre of the active screen; **esc** or clicking away dismisses it.
- Spotlight-style UI: one neutral system Liquid Glass bar (`glassEffect(.regular)`, no tint) that expands into grouped results, with the system accent colour for selection and full light and dark mode.
- Search over 16 built-in **fake** records (Accounts, Contacts, Opportunities, Cases, Reports, Setup pages): case- and diacritic-insensitive substring match on title and subtitle, grouped by type, with **↑ / ↓** selection.
- `scripts/build-app.sh` to package `Glassforce.app` (`LSUIElement`, versioned `Info.plist`, ad-hoc signed).
- Debug launch flags for demos and screenshots: `--show-panel`, `--query`, `--pin`, `--backdrop`, `--appearance light|dark`.
- swift-testing suites for the record store, search, selection and launch options.
- CI on GitHub Actions (macOS 26 runner), security policy, contributing guide, issue and PR templates.

[Unreleased]: https://github.com/srikolagani/glassforce-public/commits/main
[0.1.0]: #010---2026-11-03
