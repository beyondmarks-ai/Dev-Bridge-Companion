# DevBridge Companion

Android companion application for secure, remote APK delivery through DevBridge.

The app pairs with a DevBridge server by scanning a short-lived QR code. After pairing, it retrieves builds, downloads an APK through a one-use authorization ticket, verifies the SHA-256 digest, and opens Android Package Installer. The developer computer and phone may use completely different internet connections.

> Development status: functional Android preview for controlled internal testing. It is not an app store, MDM platform, or silent installer.

## Features

- QR scanning with a dedicated camera overlay.
- Strict QR validation:
  - Public hosts require HTTPS.
  - Plain HTTP is allowed only for loopback, emulator, and private-LAN addresses.
- Explicit server and device-name confirmation before pairing.
- Encrypted device-token storage using the Android Keystore-backed secure-storage plugin.
- Automatic connection restoration and session polling.
- Project, application, package, version, build, and artifact-size display.
- Authenticated one-use APK download URLs.
- Download progress and user-visible failure states.
- Client-side SHA-256 verification before installation.
- Android unknown-source permission guidance.
- Android `PackageInstaller` sessions with structured success and failure reasons.
- Automatic reporting of download, verification, installation, and launch outcomes.
- Device, OS, ABI, screen-size, density, text-scale, orientation, and theme context.
- Automatic launch of a successfully installed package when its package name is configured.
- Included `devbridge_diagnostics` Flutter package for opt-in target-app telemetry.
- Secure disconnect and credential removal.

## How it works

```text
Developer dashboard                 DevBridge Companion
        │                                  │
        │ creates one-time QR              │ scans + confirms
        └──────────────┬───────────────────┘
                       ▼
              DevBridge HTTPS API
              ├── exchanges pairing token
              ├── issues scoped device token
              ├── lists available builds
              └── issues one-use download ticket
                       │
                       ▼
              download → SHA-256 verify
                       │
                       ▼
              Android PackageInstaller session
                       │
                       ▼
        status + launch result → diagnostics dashboard
```

The companion cannot silently install an APK on a normal personal Android device. Android requires the user to allow installation from this source and confirm each install or update.

## Repository layout

```text
.
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml
│       └── kotlin/.../MainActivity.kt   PackageInstaller session bridge
├── lib/
│   ├── models/devbridge_models.dart     Protocol models and QR validation
│   ├── services/apk_installer.dart      Flutter platform-channel client
│   ├── services/credential_store.dart   Encrypted credentials
│   ├── services/devbridge_api.dart      Pair, poll, download, and verify
│   └── main.dart                        Application state and UI
├── packages/devbridge_diagnostics/      Target-app crash/performance SDK
├── test/
│   └── pairing_payload_test.dart
└── pubspec.yaml
```

## Requirements

- Flutter stable with Dart 3.12+
- Android SDK with API 24+ support
- Java 17
- A reachable DevBridge server
- A physical Android device for camera and installer testing

## Setup

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Build a debug APK:

```bash
flutter build apk --debug
```

The artifact is written to:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

For smaller distribution artifacts, configure production signing and build a release APK or split APKs:

```bash
flutter build apk --release --split-per-abi
```

Do not distribute a release that uses the template debug signing configuration.

## Pairing and installation

1. Open the DevBridge dashboard and create a named project/app session.
2. Open this companion and tap **Scan DevBridge QR**.
3. Review the server origin and device name, then approve pairing.
4. Upload a signed target APK from the developer dashboard.
5. Tap **Install** beside the build.
6. Wait for download and SHA-256 verification.
7. If Android opens **Allow from this source**, enable it for DevBridge.
8. Return to DevBridge and tap **Install** again.
9. Confirm the installation in Android Package Installer.

Updates must use the same Android application ID and signing certificate as the installed target, with a valid version-code progression.

## Connection modes

### Hosted mode

The QR contains a public HTTPS origin. Phone and developer computer can use different networks, including mobile data and office/home Wi-Fi. Neither needs an inbound port or public IP.

### Local development mode

The QR contains a private IPv4 address such as `http://192.168.1.20:5074`. The phone must be able to route to that address, and the workstation firewall must allow the server port.

Cleartext Android traffic is enabled only to support this private-LAN mode. Public non-HTTPS QR origins are rejected in Dart before any pairing request is made.

## Security notes

- Treat the QR as a temporary invitation and do not post it publicly.
- Device tokens are stored with `flutter_secure_storage`, not ordinary preferences.
- Download tickets are scoped, one-use, and short-lived.
- The downloaded bytes are verified against the server-provided SHA-256 before installer launch.
- APK bytes are streamed into an Android-owned package installation session.
- The companion never receives the developer access key.
- Diagnostic features must redact authorization headers, credentials, personal data, and sensitive API payloads.

See [SECURITY.md](SECURITY.md) for responsible reporting and deployment considerations.

## Known limitations

- Android is the only configured target platform.
- The application ID is still the Flutter template identifier and must be changed before branded public distribution.
- Release signing is not configured; the template currently uses debug signing.
- There are no background build notifications yet.
- Downloads are not resumable after process termination.
- Automatic private runtime telemetry requires the target app to initialize the included opt-in SDK.
- The bundled scanner makes debug builds relatively large.

## Roadmap

### Distribution experience

- Resumable downloads and Android notification progress.
- Background build-ready notifications.
- Build release notes, channels, expiry, and installation history.
- Signing-certificate verification and expected-package validation.
- Delta-aware updates where Android packaging permits.

### Testing and feedback

- Screenshot annotation, screen recording, voice notes, and structured issue types.
- Device/app/network diagnostics attached to tester reports.
- Offline feedback queue with retry and delivery confirmation.
- Test checklists and pass/fail results per build.

### Diagnostics SDK

- Native Android historical exit, ANR, and native-crash support.
- Redacted HTTP breadcrumbs and persistent offline buffering.
- Sampling, explicit consent controls, and project-level collection policies.

### Platform and enterprise

- iOS tester distribution workflow where platform rules permit.
- Track `mobile_scanner` and migrate when its built-in Kotlin support is released.
- Microsoft Entra user identity and organization membership.
- Android Enterprise managed-device installation.
- Accessibility, localization, tablet layouts, and branded themes.

## Validation

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

CI runs these checks for pull requests and pushes to `main`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

No open-source license has been assigned yet. Until a license is added, all rights are reserved by the repository owner.
