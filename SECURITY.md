# Security

## Commitments

Glassforce keeps these commitments.

- Glassforce stores refresh tokens only in the macOS Keychain. Access tokens stay in memory. Neither is written in plain text to disk, to `UserDefaults`, to logs, or to crash reports.
- Glassforce signs in with OAuth 2.0 authorization code and PKCE, in the system browser sheet. It does not receive the Salesforce password or the MFA codes.
- Glassforce does not collect telemetry, analytics, or crash reports.
- Normal sign-in, sync, and update flows use Salesforce endpoints. Automatic HTTP redirects are refused. Token-response instance and identity URLs are trusted; per-org destination binding is not yet enforced. The development mock flag uses a fake Salesforce on `127.0.0.1`.
- Glassforce is a public OAuth client. There is no client secret. PKCE protects the authorization code.
- Requested scopes are `api`, `refresh_token`, and `id`.

## Current limitations

- Synced org fields are stored in local SQLite and JSON files without application-level encryption. Protect the Mac account and disk accordingly.
- Stage updates require confirmation and validate the cached before-value. They do not use server-side optimistic concurrency and can overwrite a change made after the last sync.
- Unit and app integration tests use synthetic fixtures. They are not a penetration test or proof of live-org acceptance.

## Supported versions

No release is tagged yet. No version is supported.

| Version | Supported |
| --- | --- |
| No tagged release | No |

## Reporting a vulnerability

Public GitHub issues are the wrong place for a security report.

Use the private reporting option on the [Security tab](https://github.com/srikolagani/glassforce-public/security) when available. If it is unavailable, ask the maintainer for a private reporting channel without posting exploit details or org data publicly.

A report includes steps to reproduce, the version that was running, and the impact.

The project acknowledges a report within 3 business days. A confirmed issue gets a fix or a mitigation plan within 30 days. The project may name the reporter in the release notes.
