# Contributing to DevBridge Companion

Thank you for improving the DevBridge Android experience.

## Before opening a pull request

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

## Pull requests

Include:

- The user problem and proposed behavior.
- Screenshots or a short recording for UI changes.
- Android version and device/emulator used for testing.
- Results for pairing, download, hash verification, and installer flows when relevant.
- Security and privacy impact, especially for storage, networking, logs, screenshots, and permissions.

Keep changes focused. Update protocol models and documentation together when server contracts change.

## Security rules

- Never commit live QR values, device tokens, access keys, tester data, signed private APKs, or signing keys.
- Do not weaken the HTTPS/private-LAN QR validation without an explicit threat-model review.
- Never bypass SHA-256 verification or expand FileProvider paths beyond the required cache directory.
- Redact credentials and personal data from errors, analytics, and diagnostics.
