# Test a Glassforce release candidate

## Automated checks

Run on macOS 26 with Swift 6.2 or newer. If the installed Command Line Tools have stale manifest interfaces, use the temporary workaround in the README; do not modify the installed toolchain.

```sh
scripts/test.sh
scripts/bench.sh
```

The suites use mocks and synthetic records. They cover search, auth state transitions, cancellation, click-only network actions, duplicate write suppression, cache refresh, window focus configuration, repeat presentation, and redirect refusal. They do not prove that a particular Salesforce org accepts the packaged client.

## Isolated panel smoke test

```sh
scripts/build-qa-panel.sh
build/GlassforcePanelQA.app/Contents/MacOS/GlassforcePanelQA --qa-root /tmp/glassforce-panel-review
```

The QA panel uses memory preferences, memory credentials, a separate file root and no production network. It does not register Option-Space. Verify typing, arrows, Cmd-K, Escape, click-away, and dragging by the search icon. Only use synthetic fixture records in screenshots.

## Installer checks

From a clean committed checkout:

```sh
scripts/release.sh
hdiutil verify build/release/Glassforce-0.1.0.dmg
codesign --verify --strict --verbose=2 build/release/Glassforce.app
```

Check the DMG contains Glassforce.app and an Applications shortcut. Compare its SHA-256 with build/release/SHA256SUMS. The app's GlassforceSourceSHA and GlassforceSourceDirty fields must match the clean source commit. Copy to a temporary folder for an integrity check; do not replace a user's installed app or delete their data as a test.

An ad-hoc signature checks integrity only. It is not Developer ID signing, notarization, or Gatekeeper acceptance. Leave quarantine and Gatekeeper enabled.

## Manual acceptance before publication

Use a dedicated test Mac account and an authorized Salesforce sandbox. Do not wipe an existing installation, reset its Keychain, uninstall an org package, or change real records merely to obtain a clean test.

- Cold launch remains quiet; Option-Space and the menu reveal the expected window.
- Typing works after switching from another app. Drag the search icon or the setup card's top edge; fields and buttons stay clickable.
- Repeat show/hide, Escape, click-away, Cmd-K and Settings flows.
- Setup: custom-domain input, Back, Cancel, retry, rejected org, repeated confirmation, and recovery after failed sync.
- Install the package only with the org administrator's authorization; confirm OAuth identity and sync read-only first.
- Any test update needs separate approval for the sandbox record and exact change. Verify both Salesforce and the refreshed cache. The app does not provide server-side optimistic concurrency protection.

Record the commit, build metadata, checks performed, failures and untested cases. Do not describe a mock test as a live acceptance test.
