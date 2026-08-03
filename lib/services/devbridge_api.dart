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
