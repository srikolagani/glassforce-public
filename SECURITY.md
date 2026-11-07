# Security

## Commitments

Glassforce keeps these commitments.

- Glassforce stores OAuth access tokens and refresh tokens only in the macOS Keychain. It does not write them in plain text to disk, to `UserDefaults`, to logs, or to crash reports.
- Glassforce signs in with OAuth 2.0 authorization code and PKCE, in the system browser sheet. It does not receive the Salesforce password or the MFA codes.
- Glassforce does not collect telemetry, analytics, or crash reports.
- Network calls go to the Salesforce org the user signed in to. The development mock flag talks only to a fake Salesforce on `127.0.0.1`.
- Glassforce is a public OAuth client. There is no client secret. PKCE protects the authorization code.
- Requested scopes are `api`, `refresh_token`, and `id`.

## Supported versions

No release is tagged yet. No version is supported.

| Version | Supported |
| --- | --- |
| No tagged release | No |

## Reporting a vulnerability

Public GitHub issues are the wrong place for a security report.

Reports go through GitHub private vulnerability reporting at <https://github.com/srikolagani/glassforce/security/advisories/new>.

A report includes steps to reproduce, the version that was running, and the impact.

The project acknowledges a report within 3 business days. A confirmed issue gets a fix or a mitigation plan within 30 days. The project may name the reporter in the release notes.
