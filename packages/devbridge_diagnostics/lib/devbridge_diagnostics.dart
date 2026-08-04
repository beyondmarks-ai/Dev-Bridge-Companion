library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class DevBridgeDiagnosticsConfig {
  const DevBridgeDiagnosticsConfig({
    required this.baseUri,
    required this.sessionId,
    required this.deviceToken,
    required this.buildId,
    this.appVersion,
    this.environment = 'test',
    this.sendPerformanceMetrics = true,
    this.captureId,
    this.captureFailureScreenshots = true,
    this.maximumBreadcrumbs = 20,
  });

  final Uri baseUri;
  final String sessionId;
  final String deviceToken;
  final String buildId;
  final String? appVersion;
  final String environment;
  final bool sendPerformanceMetrics;
  final String? captureId;
  final bool captureFailureScreenshots;
  final int maximumBreadcrumbs;
}

class DevBridgeDiagnostics with WidgetsBindingObserver {
  DevBridgeDiagnostics._(this._config, this._client);

  static DevBridgeDiagnostics? _instance;
  static const MethodChannel _native = MethodChannel('devbridge/diagnostics');

  final DevBridgeDiagnosticsConfig _config;
  final http.Client _client;
  final List<Map<String, Object?>> _pending = [];
  final List<FrameTiming> _frames = [];
  final List<_DiagnosticBreadcrumb> _breadcrumbs = [];
  DevBridgeCaptureController? _captureController;
  Timer? _flushTimer;
  String? _screen;
  bool _flushing = false;
  FlutterExceptionHandler? _previousFlutterHandler;
  FlutterExceptionHandler? _installedFlutterHandler;
  bool Function(Object, StackTrace)? _previousPlatformHandler;
  bool Function(Object, StackTrace)? _installedPlatformHandler;

  static DevBridgeDiagnostics get instance {
    final value = _instance;
    if (value == null) {
      throw StateError(
        'Call DevBridgeDiagnostics.initialize before using the SDK.',
      );
    }
    return value;
  }

  static Future<DevBridgeDiagnostics> initialize(
    DevBridgeDiagnosticsConfig config, {
    http.Client? client,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    await _instance?.dispose();
    final diagnostics = DevBridgeDiagnostics._(config, client ?? http.Client());
    _instance = diagnostics;
    diagnostics._installHandlers();
    WidgetsBinding.instance.addObserver(diagnostics);
    if (config.sendPerformanceMetrics) {
      WidgetsBinding.instance.addTimingsCallback(diagnostics._onFrameTimings);
    }
    diagnostics._flushTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(diagnostics.flush()),
    );
    await diagnostics.capture(
      category: 'lifecycle',
      eventType: 'sdk_initialized',
      message: 'DevBridge diagnostics initialized.',
      context: {
        'appVersion': config.appVersion ?? 'unknown',
        'environment': config.environment,
        'platform': Platform.operatingSystem,
        'platformVersion': Platform.operatingSystemVersion,
        'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
      },
    );
    return diagnostics;
  }

  static Future<DevBridgeDiagnostics?> initializeFromLaunch({
    http.Client? client,
    String? appVersion,
    String environment = 'test',
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    Map<Object?, Object?>? handoff;
    try {
      handoff = await _native.invokeMethod<Map<Object?, Object?>>(
        'getLaunchHandoff',
      );
    } on MissingPluginException {
      return null;
    }
    if (handoff == null) return null;
    final baseUri = Uri.tryParse(handoff['baseUrl'] as String? ?? '');
    final handoffToken = handoff['handoffToken'] as String?;
    final captureId = handoff['captureId'] as String?;
    if (baseUri == null || handoffToken == null) return null;
    final transport = client ?? http.Client();
    try {
      final response = await transport
          .post(
            baseUri.resolve('/api/sdk/exchange'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'handoffToken': handoffToken}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final diagnostics = await initialize(
        DevBridgeDiagnosticsConfig(
          baseUri: Uri.parse(json['baseUrl'] as String),
          sessionId: json['sessionId'] as String,
          deviceToken: json['sdkToken'] as String,
          buildId: json['buildId'] as String,
          appVersion: appVersion,
          environment: environment,
          captureId: captureId,
        ),
        client: transport,
      );
      await diagnostics._captureHistoricalExits();
      return diagnostics;
    } catch (_) {
      if (client == null) transport.close();
      return null;
    }
  }

  Future<void> _captureHistoricalExits() async {
    List<Object?> exits;
    try {
      exits =
          await _native.invokeMethod<List<Object?>>(
            'getHistoricalExitReasons',
          ) ??
          const [];
    } on MissingPluginException {
      return;
    }
    for (final raw in exits) {
      final exit = Map<String, Object?>.from(raw! as Map);
      final reason = exit['reason'] as String? ?? 'unknown';
      final isAnr = reason == 'anr';
      final isCrash = reason == 'native_crash' || reason == 'java_crash';
      await capture(
        category: isAnr
            ? 'anr'
            : isCrash
            ? 'crash'
            : 'process_exit',
        eventType: 'historical_$reason',
        level: isAnr || isCrash ? 'fatal' : 'warning',
        message:
            'Previous application process exited because of ${reason.replaceAll('_', ' ')}.',
        details: exit['description'] as String?,
        stackTrace: exit['trace'] == null
            ? null
            : StackTrace.fromString(exit['trace'] as String),
        metrics: {
          'pssKb': (exit['pssKb'] as num?)?.toDouble() ?? 0,
          'rssKb': (exit['rssKb'] as num?)?.toDouble() ?? 0,
          'status': (exit['status'] as num?)?.toDouble() ?? 0,
        },
        context: {
          'traceEncoding': exit['traceEncoding'] as String? ?? 'none',
          'reasonCode': '${exit['reasonCode']}',
          'importance': '${exit['importance']}',
        },
      );
    }
    await flush();
  }

  void _installHandlers() {
    _previousFlutterHandler = FlutterError.onError;
    _installedFlutterHandler = (details) {
      unawaited(
        _captureFailure(
          eventType: 'flutter_error',
          level: 'error',
          message: details.exceptionAsString(),
          details: details.context?.toDescription(),
          stackTrace: details.stack,
        ),
      );
      if (_previousFlutterHandler != null) {
        _previousFlutterHandler!(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    FlutterError.onError = _installedFlutterHandler;

    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    _installedPlatformHandler = (error, stack) {
      unawaited(
        _captureFailure(
          eventType: 'uncaught_async_error',
          level: 'fatal',
          message: error.toString(),
          stackTrace: stack,
        ),
      );
      return _previousPlatformHandler?.call(error, stack) ?? false;
    };
    PlatformDispatcher.instance.onError = _installedPlatformHandler;
  }

  Future<void> _captureFailure({
    required String eventType,
    required String level,
    required String message,
    String? details,
    StackTrace? stackTrace,
  }) async {
    final fingerprint = _stableFingerprint(
      'crash|$eventType|$message|${stackTrace?.toString().split('\n').first ?? ''}',
    );
    String? attachmentId;
    if (_config.captureFailureScreenshots && _captureController != null) {
      try {
        final bytes = await _captureController!._capturePng();
        if (bytes != null) {
          attachmentId = await uploadAttachment(
            bytes: bytes,
            fileName: 'failure-${DateTime.now().millisecondsSinceEpoch}.png',
            contentType: 'image/png',
            kind: 'failure-screenshot',
            fingerprint: fingerprint,
            capturedAt: DateTime.now().toUtc(),
          );
        }
      } catch (_) {
        // A screenshot is supporting evidence and must never suppress the crash.
      }
    }
    await capture(
      category: 'crash',
      eventType: eventType,
      level: level,
      message: message,
      details: details,
      stackTrace: stackTrace,
      fingerprint: fingerprint,
      context: attachmentId == null ? null : {'attachmentId': attachmentId},
    );
  }

  Future<void> capture({
    required String category,
    required String eventType,
    required String message,
    String level = 'info',
    String? details,
    StackTrace? stackTrace,
    Map<String, double>? metrics,
    Map<String, String>? context,
    String? fingerprint,
  }) async {
    final includeBreadcrumbs =
        level == 'error' ||
        level == 'fatal' ||
        category == 'crash' ||
        category == 'anr';
    final mergedContext = <String, String>{...?context};
    final captureId = _config.captureId;
    if (captureId != null) mergedContext['captureId'] = captureId;
    if (includeBreadcrumbs) mergedContext.addAll(_breadcrumbContext());
    _pending.add({
      'level': level,
      'category': category,
      'eventType': eventType,
      'message': message,
      'details': details,
      'stackTrace': stackTrace?.toString(),
      'screen': _screen,
      'buildId': _config.buildId,
      'metrics': metrics,
      'context': mergedContext,
      'fingerprint': fingerprint,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (_pending.length > 200) _pending.removeRange(0, _pending.length - 200);
    if (_pending.length >= 10 || level == 'fatal') await flush();
  }

  void setCurrentScreen(String? screen) {
    if (screen == null || screen.trim().isEmpty || screen == _screen) return;
    _screen = screen.trim();
    recordBreadcrumb(kind: 'navigation', message: 'Opened $_screen.');
    unawaited(
      capture(
        category: 'navigation',
        eventType: 'screen_view',
        message: 'Opened $_screen.',
      ),
    );
  }

  void attachCaptureController(DevBridgeCaptureController controller) {
    _captureController = controller;
  }

  void recordAction(String label, {Map<String, String>? metadata}) {
    recordBreadcrumb(kind: 'action', message: label, metadata: metadata);
  }

  void recordBreadcrumb({
    required String kind,
    required String message,
    Map<String, String>? metadata,
  }) {
    final cleanMetadata = <String, String>{};
    for (final entry in (metadata ?? const <String, String>{}).entries.take(
      6,
    )) {
      cleanMetadata[_safeText(entry.key, 40)] = _safeText(entry.value, 120);
    }
    _breadcrumbs.add(
      _DiagnosticBreadcrumb(
        occurredAt: DateTime.now().toUtc(),
        kind: _safeText(kind, 30),
        message: _safeText(message, 160),
        metadata: cleanMetadata,
      ),
    );
    final maximum = _config.maximumBreadcrumbs.clamp(5, 30);
    if (_breadcrumbs.length > maximum) {
      _breadcrumbs.removeRange(0, _breadcrumbs.length - maximum);
    }
  }

  Map<String, String> _breadcrumbContext() {
    final selected = _breadcrumbs.reversed.take(15).toList().reversed;
    var index = 1;
    return {
      for (final item in selected)
        'breadcrumb.${index++}': jsonEncode({
          'at': item.occurredAt.toIso8601String(),
          'kind': item.kind,
          'message': item.message,
          if (item.metadata.isNotEmpty) 'metadata': item.metadata,
        }),
    };
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (_frames.length < 60) return;
    final sample = List<FrameTiming>.of(_frames);
    _frames.clear();
    final totals = sample
        .map((frame) => frame.totalSpan.inMicroseconds / 1000)
        .toList();
    final slow = totals.where((duration) => duration > 32).length;
    final worst = totals.reduce((a, b) => a > b ? a : b);
    final average = totals.reduce((a, b) => a + b) / totals.length;
    if (slow == 0 && worst < 50) return;
    unawaited(
      capture(
        category: 'performance',
        eventType: 'slow_frames',
        level: slow / totals.length >= .1 ? 'warning' : 'info',
        message:
            '$slow slow frames detected on ${_screen ?? 'the current screen'}.',
        metrics: {
          'sampleFrames': totals.length.toDouble(),
          'slowFrames': slow.toDouble(),
          'slowFramePercent': slow / totals.length * 100,
          'averageFrameMs': average,
          'worstFrameMs': worst,
        },
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    recordBreadcrumb(
      kind: 'lifecycle',
      message: 'Application changed to ${state.name}.',
    );
    unawaited(
      capture(
        category: 'lifecycle',
        eventType: 'app_${state.name}',
        message: 'Application lifecycle changed to ${state.name}.',
      ),
    );
  }

  Future<void> flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    final batch = _pending.take(100).toList(growable: false);
    try {
      final response = await _client
          .post(
            _config.baseUri.resolve(
              '/api/sessions/${_config.sessionId}/diagnostics/batch',
            ),
            headers: {
              'Authorization': 'Bearer ${_config.deviceToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'events': batch}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _pending.removeRange(0, batch.length);
      }
    } catch (_) {
      // Retain the bounded in-memory queue for the next flush attempt.
    } finally {
      _flushing = false;
    }
  }

  Future<String?> uploadAttachment({
    required List<int> bytes,
    required String fileName,
    required String contentType,
    required String kind,
    String? fingerprint,
    String? captureId,
    DateTime? capturedAt,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            _config.baseUri.resolve(
              '/api/sessions/${_config.sessionId}/attachments',
            ),
          )
          ..headers['Authorization'] = 'Bearer ${_config.deviceToken}'
          ..fields['buildId'] = _config.buildId
          ..fields['kind'] = kind
          ..fields['captureId'] = captureId ?? _config.captureId ?? ''
          ..fields['fingerprint'] = fingerprint ?? ''
          ..fields['capturedAt'] = (capturedAt ?? DateTime.now().toUtc())
              .toUtc()
              .toIso8601String()
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: fileName,
              contentType: MediaType.parse(contentType),
            ),
          );
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final body = await response.stream.bytesToString();
    return (jsonDecode(body) as Map<String, dynamic>)['attachmentId']
        as String?;
  }

  static String _stableFingerprint(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return 'sdk-${hash.toRadixString(16).padLeft(16, '0')}';
  }

  static String _safeText(String value, int maximum) {
    var clean = value.replaceAll(
      RegExp(
        r'(authorization|cookie|token|password|secret|api[-_]?key)(\s*[:=]\s*)([^\s,;]+)',
        caseSensitive: false,
      ),
      r'$1$2[REDACTED]',
    );
    if (clean.length > maximum) clean = clean.substring(0, maximum);
    return clean;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_config.sendPerformanceMetrics) {
      WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
    await flush();
    if (identical(FlutterError.onError, _installedFlutterHandler)) {
      FlutterError.onError = _previousFlutterHandler;
    }
    if (identical(
      PlatformDispatcher.instance.onError,
      _installedPlatformHandler,
    )) {
      PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
    _client.close();
    if (identical(_instance, this)) _instance = null;
  }
}

class _DiagnosticBreadcrumb {
  const _DiagnosticBreadcrumb({
    required this.occurredAt,
    required this.kind,
    required this.message,
    required this.metadata,
  });

  final DateTime occurredAt;
  final String kind;
  final String message;
  final Map<String, String> metadata;
}

class DevBridgeHttpClient extends http.BaseClient {
  DevBridgeHttpClient(this._diagnostics, {http.Client? inner})
    : _inner = inner ?? http.Client();

  final DevBridgeDiagnostics _diagnostics;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stopwatch = Stopwatch()..start();
    final endpoint = _safeEndpoint(request.url);
    _diagnostics.recordBreadcrumb(
      kind: 'network',
      message: '${request.method} $endpoint started',
    );
    try {
      final response = await _inner.send(request);
      stopwatch.stop();
      _diagnostics.recordBreadcrumb(
        kind: 'network',
        message: '${request.method} $endpoint returned ${response.statusCode}',
        metadata: {'durationMs': '${stopwatch.elapsedMilliseconds}'},
      );
      if (response.statusCode >= 500) {
        unawaited(
          _diagnostics.capture(
            category: 'network',
            eventType: 'server_error',
            level: 'error',
            message:
                '${request.method} $endpoint returned ${response.statusCode}.',
            metrics: {
              'durationMs': stopwatch.elapsedMilliseconds.toDouble(),
              'statusCode': response.statusCode.toDouble(),
            },
          ),
        );
      }
      return response;
    } catch (error) {
      stopwatch.stop();
      _diagnostics.recordBreadcrumb(
        kind: 'network',
        message: '${request.method} $endpoint failed',
        metadata: {
          'durationMs': '${stopwatch.elapsedMilliseconds}',
          'errorType': error.runtimeType.toString(),
        },
      );
      unawaited(
        _diagnostics.capture(
          category: 'network',
          eventType: 'request_failed',
          level: 'error',
          message: '${request.method} $endpoint failed.',
          details: error.runtimeType.toString(),
          metrics: {'durationMs': stopwatch.elapsedMilliseconds.toDouble()},
        ),
      );
      rethrow;
    }
  }

  static String _safeEndpoint(Uri uri) {
    final segments = uri.pathSegments.map((segment) {
      if (RegExp(r'^\d{4,}$').hasMatch(segment) ||
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f-]{27,}$',
            caseSensitive: false,
          ).hasMatch(segment)) {
        return ':id';
      }
      return segment.length > 50 ? ':value' : segment;
    });
    return Uri(pathSegments: segments).path;
  }

  @override
  void close() => _inner.close();
}

class DevBridgeCaptureController {
  final GlobalKey boundaryKey = GlobalKey();

  Future<Uint8List?> _capturePng({double pixelRatio = 1.5}) async {
    final context = boundaryKey.currentContext;
    if (context == null) return null;
    final boundary = context.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || boundary.debugNeedsPaint) return null;
    final image = await boundary.toImage(pixelRatio: pixelRatio.clamp(1, 3));
    final data = await image.toByteData(format: ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return data.buffer.asUint8List();
  }

  Future<String?> captureScreenshot({double pixelRatio = 1.5}) async {
    final bytes = await _capturePng(pixelRatio: pixelRatio);
    if (bytes == null) return null;
    return DevBridgeDiagnostics.instance.uploadAttachment(
      bytes: bytes,
      fileName: 'devbridge-${DateTime.now().millisecondsSinceEpoch}.png',
      contentType: 'image/png',
      kind: 'screenshot',
    );
  }
}

class DevBridgeCaptureBoundary extends StatelessWidget {
  const DevBridgeCaptureBoundary({
    required this.controller,
    required this.child,
    super.key,
  });

  final DevBridgeCaptureController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final diagnostics = DevBridgeDiagnostics._instance;
    diagnostics?.attachCaptureController(controller);
    final size = MediaQuery.sizeOf(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (event) => diagnostics?.recordAction(
        'Pointer released',
        metadata: {
          'x': event.position.dx.toStringAsFixed(0),
          'y': event.position.dy.toStringAsFixed(0),
          'screenWidth': size.width.toStringAsFixed(0),
          'screenHeight': size.height.toStringAsFixed(0),
        },
      ),
      child: RepaintBoundary(key: controller.boundaryKey, child: child),
    );
  }
}

class DevBridgeNavigatorObserver extends NavigatorObserver {
  void _record(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) DevBridgeDiagnostics.instance.setCurrentScreen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _record(newRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record(previousRoute);
}
