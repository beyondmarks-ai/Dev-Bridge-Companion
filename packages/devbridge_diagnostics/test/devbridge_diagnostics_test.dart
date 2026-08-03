import 'dart:convert';

import 'package:devbridge_diagnostics/devbridge_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'batches authenticated diagnostics using the session endpoint',
    () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 202);
      });
      final diagnostics = await DevBridgeDiagnostics.initialize(
        DevBridgeDiagnosticsConfig(
          baseUri: Uri.parse('https://devbridge.example'),
          sessionId: 'session-id',
          deviceToken: 'device-token',
          buildId: '00000000-0000-0000-0000-000000000001',
        ),
        client: client,
      );

      await diagnostics.capture(
        category: 'crash',
        eventType: 'test_error',
        level: 'fatal',
        message: 'Test failure',
        stackTrace: StackTrace.current,
      );

      expect(captured?.url.path, '/api/sessions/session-id/diagnostics/batch');
      expect(captured?.headers['Authorization'], 'Bearer device-token');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final events = body['events'] as List<dynamic>;
      expect(events, hasLength(2));
      expect((events.last as Map<String, dynamic>)['eventType'], 'test_error');

      await diagnostics.dispose();
    },
  );
}
