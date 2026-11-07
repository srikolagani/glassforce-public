# Onboarding design (v3)

## Why
v2 still read homemade: flat opaque gray windows, `STEP 1 OF 2` fighting five dots, a tall empty void under sparse steps, web-form environment chrome, and panel proof that showed “No Results” on a black capture.

## What changed in v3

### Liquid Glass window
- Onboarding is a **borderless clear window** (same pattern as the command bar). Content sits in a **floating `.glassEffect(.regular)` card** with clear margin so the desktop shows around it.
- Proof shots use `--backdrop` (calm desktop gradient) and `screencapture -R` so glass is captured with the backdrop visible — not window-ID alone (which blacks out translucency).

### One progress system
- Dropped the `STEP 1 OF 2` eyebrow. **Dots only.**

### Compact, balanced layout
- Glass card is **480×360** inside a **560×440** clear host. Step bodies vertically center with spacers. Shared trailing footer on every step (Get Started / Continue / Install / Proceed / Connect all bottom-trailing).

### Environment row
- Segmented control + native field chrome: `textBackgroundColor` fill, separator stroke, secondary SF Symbol (`building.2` / `testtube.2` / `link`).

### Install progress copy
- After opening the package page: secondary `Label` with `checkmark.circle.fill` — progress, not another button.

### Panel proof
- `--fake-data --query acme --backdrop` so results + quiet `Sandbox · Acme Demo` badge show in context over glass.

### Proof hygiene
- `--onboarding-step` uses `InMemorySecretStore` (no Keychain Allow sheets over the UI).
- Mock hammer banner suppressed when `suppressDevChrome` is set for step shots.

## Apple patterns
- Spotlight / command-bar clear host + glass capsule
- System Settings segmented control
- Setup Assistant: one `.borderedProminent` primary, quiet secondary text
- Secondary-label org chips (not shouty pills)

## Out of scope
No new product features. Live auth / Keychain for real users unchanged.
