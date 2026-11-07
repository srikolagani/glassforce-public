# Glassforce's packaged External Client App

Goal: one package any Salesforce org can install, so every user signs in with the same consumer key and no admin creates an app by hand.

## How it works
- Default is an **unlocked** package with no namespace, built from one Dev Hub (flxbl-io/external-client-apps-guide, pattern 1).
- The ECA (`Glassforce_App`, `distributionState` Packaged, OAuth on, PKCE, callback `dev.glassforce.app://oauth/callback`, scopes Basic/Api/RefreshToken) lives in the Dev Hub. Its global OAuth settings (the consumer key) stay there and are never packaged.
- The package holds only `ExternalClientApplication` and `ExtlClntAppOauthSettings` retrieved from the Dev Hub, so it carries the platform's `oauthLink`. Installing orgs resolve the Dev Hub's consumer through it.
- `PACKAGE_TYPE=Managed NAMESPACE=<prefix>` builds a managed 2GP package instead (needs a namespace linked to the Dev Hub).

## Run it
```sh
DEVHUB=<devhub alias> CONTACT_EMAIL=<email> PROMOTE=1 TARGET_ORG=<test org alias> scripts/package-eca.sh
scripts/build-app.sh
```
Without DEVHUB it is a dry run. Steps: create the ECA in the Dev Hub if missing (header, OAuth settings, global OAuth settings, OAuth policies), retrieve header + OAuth settings, create the package if missing, create a version (`--code-coverage --installation-key-bypass`), promote when `PROMOTE=1` (needed for Developer Edition and production orgs), read the consumer key into `config/glassforce.local.env` (gitignored, chmod 600, never printed), and with `TARGET_ORG` install the version there and run `scripts/check-authorize.sh`.

## Checking a key against an org without clicking
`CONSUMER_KEY=... scripts/check-authorize.sh <alias>` opens the authorize endpoint as the CLI's user in that org and reports one of: consent page (key accepted), `OAUTH_AUTHORIZATION_BLOCKED` cross-org (a Local ECA's key), or `invalid_client_id`. It writes nothing to the org.

## Gotchas seen
- `sf package create` rewrites `sfdx-project.json` (default false, 0.1.0); the script puts its own back.
- Right after the ECA is created, version create can fail with "There was a problem with the OAuth link ... wait 10-15 minutes"; rerun later.
- Upgrades of unlocked ECA packages are reported to fail in some setups (zenn.dev/cariot_dev); untested here.
