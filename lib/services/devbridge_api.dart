import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/devbridge_models.dart';

class DevBridgeException implements Exception {
  const DevBridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DevBridgeApi {
  DevBridgeApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<ConnectionCredentials> pair({
    required PairingPayload payload,
    required String deviceName,
    required String platformVersion,
    required Map<String, String> context,
  }) async {
    final response = await _client
        .post(
          payload.baseUri.resolve('/api/sessions/${payload.sessionId}/pair'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pairingToken': payload.pairingToken,
            'deviceName': deviceName,
            'platform': 'Android',
            'platformVersion': platformVersion,
            'context': context,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw DevBridgeException(
        response.statusCode == 401
            ? 'This QR code has expired or was already used.'
            : 'DevBridge rejected the connection (${response.statusCode}).',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return ConnectionCredentials(
      baseUri: payload.baseUri,
      sessionId: payload.sessionId,
      deviceId: json['deviceId'] as String,
      deviceToken: json['deviceToken'] as String,
      deviceName: deviceName,
    );
  }

  Future<void> reportInstallation({
    required ConnectionCredentials credentials,
    required DevBridgeBuild build,
    required String status,
    required String message,
    String? packageName,
    int? statusCode,
    String? details,
  }) async {
    final response = await _client
        .post(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/installations',
          ),
          headers: {
            'Authorization': 'Bearer ${credentials.deviceToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'buildId': build.id,
            'status': status,
            'message': message,
            'packageName': packageName,
            'statusCode': statusCode,
            'details': details,
            'occurredAt': DateTime.now().toUtc().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 202) {
      throw DevBridgeException(
        'Could not report installation result (${response.statusCode}).',
      );
    }
  }

  Future<void> reportDiagnostic({
    required ConnectionCredentials credentials,
    required String category,
    required String eventType,
    required String message,
    String level = 'info',
    String? details,
    String? fingerprint,
    String? screen,
    String? buildId,
    Map<String, double>? metrics,
    Map<String, String>? context,
  }) async {
    final response = await _client
        .post(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/diagnostics/batch',
          ),
          headers: {
            'Authorization': 'Bearer ${credentials.deviceToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'events': [
              {
                'level': level,
                'category': category,
                'eventType': eventType,
                'message': message,
                'details': details,
                'fingerprint': fingerprint,
                'screen': screen,
                'buildId': buildId,
                'metrics': metrics,
                'context': context,
                'occurredAt': DateTime.now().toUtc().toIso8601String(),
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 202) {
      throw DevBridgeException(
        'Could not report diagnostic event (${response.statusCode}).',
      );
    }
  }

  Future<SdkHandoff> createSdkHandoff({
    required ConnectionCredentials credentials,
    required DevBridgeBuild build,
  }) async {
    final response = await _client
        .post(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/builds/${build.id}/sdk-ticket',
          ),
          headers: {'Authorization': 'Bearer ${credentials.deviceToken}'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw DevBridgeException(
        'Could not create the secure SDK handoff (${response.statusCode}).',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SdkHandoff(
      token: json['handoffToken'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  Future<String> uploadAttachment({
    required ConnectionCredentials credentials,
    required File file,
    required String kind,
    required DevBridgeBuild build,
    String? fingerprint,
    String? captureId,
    DateTime? capturedAt,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            credentials.baseUri.resolve(
              '/api/sessions/${credentials.sessionId}/attachments',
            ),
          )
          ..headers['Authorization'] = 'Bearer ${credentials.deviceToken}'
          ..fields['kind'] = kind
          ..fields['buildId'] = build.id
          ..fields['fingerprint'] = fingerprint ?? ''
          ..fields['captureId'] = captureId ?? ''
          ..fields['capturedAt'] = (capturedAt ?? DateTime.now().toUtc())
              .toUtc()
              .toIso8601String()
          ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 3));
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DevBridgeException(
        'Attachment upload failed (${response.statusCode}).',
      );
    }
    return (jsonDecode(body) as Map<String, dynamic>)['attachmentId'] as String;
  }

  Future<SessionSnapshot> getSession(ConnectionCredentials credentials) async {
    final response = await _client
        .get(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/device',
          ),
          headers: {'Authorization': 'Bearer ${credentials.deviceToken}'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 401 || response.statusCode == 404) {
      throw const DevBridgeException('The DevBridge session has expired.');
    }
    if (response.statusCode != 200) {
      throw DevBridgeException('Connection failed (${response.statusCode}).');
    }
    return SessionSnapshot.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> startTestRun({
    required ConnectionCredentials credentials,
    required GuidedTestRun run,
    required String captureId,
  }) async {
    final response = await _client
        .post(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/test-runs/${run.id}/start',
          ),
          headers: {
            'Authorization': 'Bearer ${credentials.deviceToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'captureId': captureId}),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw DevBridgeException(
        'Could not start the guided test (${response.statusCode}).',
      );
    }
  }

  Future<TestCompletionResult> completeTestRun({
    required ConnectionCredentials credentials,
    required GuidedTestRun run,
    required String verdict,
    required String captureId,
    String? notes,
  }) async {
    final response = await _client
        .post(
          credentials.baseUri.resolve(
            '/api/sessions/${credentials.sessionId}/test-runs/${run.id}/complete',
          ),
          headers: {
            'Authorization': 'Bearer ${credentials.deviceToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'verdict': verdict,
            'notes': notes,
            'captureId': captureId,
          }),
        )
        .timeout(const Duration(minutes: 2));
    final json = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw DevBridgeException(
        json['error'] as String? ??
            'Could not complete the guided test (${response.statusCode}).',
      );
    }
    final analysis = json['analysis'] as Map<String, dynamic>?;
    return TestCompletionResult(
      analysis: analysis == null ? null : AiDiagnosis.fromJson(analysis),
      analysisMessage: json['analysisMessage'] as String?,
    );
  }

  Future<File> downloadBuild({
    required ConnectionCredentials credentials,
    required DevBridgeBuild build,
    required void Function(int received, int? total) onProgress,
  }) async {
    final ticketResponse = await _client.post(
      credentials.baseUri.resolve(
        '/api/sessions/${credentials.sessionId}/builds/${build.id}/ticket',
      ),
      headers: {'Authorization': 'Bearer ${credentials.deviceToken}'},
    );
    if (ticketResponse.statusCode != 200) {
      throw DevBridgeException(
        'Download authorization failed (${ticketResponse.statusCode}).',
      );
    }
    final ticket = jsonDecode(ticketResponse.body) as Map<String, dynamic>;
    final downloadUrl = Uri.parse(ticket['downloadUrl'] as String);
    final request = http.Request('GET', downloadUrl);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw DevBridgeException('APK download failed (${response.statusCode}).');
    }

    final tempDirectory = await getTemporaryDirectory();
    final downloadDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}devbridge',
    );
    await downloadDirectory.create(recursive: true);
    final output = File(
      '${downloadDirectory.path}${Platform.pathSeparator}${build.id}.apk',
    );
    final sink = output.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, response.contentLength);
      }
    } finally {
      await sink.close();
    }

    final digest = await sha256.bind(output.openRead()).first;
    if (digest.toString().toUpperCase() != build.sha256.toUpperCase()) {
      await output.delete();
      throw const DevBridgeException(
        'Security check failed: downloaded APK hash does not match.',
      );
    }
    return output;
  }

  void close() => _client.close();
}
