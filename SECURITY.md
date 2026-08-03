# Security Policy

## Supported versions

DevBridge Companion is an internal-QA preview. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

Report security issues privately to the repository owner. Do not open a public issue containing pairing URLs, tokens, APKs, device identifiers, tester information, or exploit details.

Include the affected commit, Android version, reproduction steps, impact, and suggested mitigation when possible.

## High-risk areas

- QR origin validation and one-time token exchange.
- Encrypted device credential storage.
- APK download authorization and hash verification.
- FileProvider scope and Package Installer intents.
- Unknown-source permission handling.
- Future logging, screenshots, feedback, and crash collection.

The companion is not designed to silently install applications or bypass Android security prompts.
