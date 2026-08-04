# DevBridge Diagnostics SDK for Flutter

Opt-in crash, lifecycle, route, and slow-frame telemetry for applications distributed through DevBridge.

## Install

Reference the package from this repository while it remains private:

```yaml
dependencies:
  devbridge_diagnostics:
    git:
      url: https://github.com/beyondmarks-ai/Dev-Bridge-Companion.git
      path: packages/devbridge_diagnostics
```

## Initialize

For builds launched by the companion, exchange the one-use handoff automatically before `runApp`:

```dart
final diagnostics = await DevBridgeDiagnostics.initializeFromLaunch(
  appVersion: '1.4.0+82',
);
```

Wrap the application in a capture boundary to enable consent-scoped pointer breadcrumbs and automatic screenshots when Flutter reports a failure:

```dart
final captureController = DevBridgeCaptureController();

runApp(DevBridgeCaptureBoundary(
  controller: captureController,
  child: MyApp(
    navigatorObservers: diagnostics == null
        ? []
        : [DevBridgeNavigatorObserver()],
  ),
));
```

Use the diagnostics HTTP client where network breadcrumbs are required. It records only the method, sanitized path, status, duration, and error type; query strings, headers, and bodies are never collected:

```dart
final client = DevBridgeHttpClient(diagnostics);
final response = await client.get(Uri.parse('$apiBase/orders'));
```

Business-level actions can be added without capturing field values:

```dart
diagnostics.recordAction('Pressed Place Order');
```

The handoff arrives as explicit intent extras for only the selected package, expires after two minutes, and can be exchanged once. The returned SDK credential is separate from the companion credential and scoped to the session and build.

Manual initialization remains available for CI or controlled test environments:

```dart
final diagnostics = await DevBridgeDiagnostics.initialize(
  DevBridgeDiagnosticsConfig(
    baseUri: Uri.parse(devBridgeUrl),
    sessionId: sessionId,
    deviceToken: deviceToken,
    buildId: buildId,
    appVersion: '1.4.0+82',
  ),
);

runApp(MyApp(
  navigatorObservers: [DevBridgeNavigatorObserver()],
));
```

Never hard-code a long-lived production secret. DevBridge device tokens are short-lived and scoped to one test session.

## Captured data

- Flutter framework and uncaught asynchronous errors
- Lifecycle transitions
- Named route changes
- Aggregated slow-frame samples
- Android historical ANRs, native crashes, low-memory kills, and initialization failures
- Target-owned screenshots through `DevBridgeCaptureBoundary`
- Developer-defined diagnostic events
- Bounded action, navigation, lifecycle, and redacted network breadcrumbs attached to failures
- Automatic failure screenshots when the app opts into `DevBridgeCaptureBoundary`

The SDK batches events, bounds its in-memory queue, and relies on the server to redact common credential fields before Azure archival.
