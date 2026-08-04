import 'package:dev_bridge/models/devbridge_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const session = '12345678-1234-1234-1234-123456789abc';
  const token = 'abcdefghijklmnopqrstuvwxyz1234567890';

  test('accepts a private-LAN DevBridge pairing URL', () {
    final value = PairingPayload.tryParse(
      'http://192.168.1.20:5074/pair.html?session=$session&token=$token',
    );
    expect(value, isNotNull);
    expect(value!.baseUri.toString(), 'http://192.168.1.20:5074');
    expect(value.sessionId, session);
  });

  test('accepts a public host only over HTTPS', () {
    expect(
      PairingPayload.tryParse(
        'https://bridge.example.com/pair.html?session=$session&token=$token',
      ),
      isNotNull,
    );
    expect(
      PairingPayload.tryParse(
        'http://bridge.example.com/pair.html?session=$session&token=$token',
      ),
      isNull,
    );
  });

  test('rejects unrelated and malformed QR values', () {
    expect(PairingPayload.tryParse('hello'), isNull);
    expect(
      PairingPayload.tryParse(
        'http://192.168.1.20/not-pairing?session=$session&token=$token',
      ),
      isNull,
    );
    expect(
      PairingPayload.tryParse(
        'http://192.168.1.20/pair.html?session=bad&token=$token',
      ),
      isNull,
    );
  });

  test('parses an assigned guided test run', () {
    final snapshot = SessionSnapshot.fromJson({
      'projectName': 'Shop',
      'appName': 'Shop Mobile',
      'packageName': 'example.shop',
      'expiresAt': '2026-08-05T00:00:00Z',
      'builds': <dynamic>[],
      'testRuns': [
        {
          'id': 'run-1',
          'testCaseId': 'case-1',
          'status': 'ready',
          'buildId': null,
          'captureId': null,
          'testCase': {
            'title': 'Complete checkout',
            'instructions': '1. Tap Pay now.',
            'expectedResult': 'Confirmation is visible.',
            'priority': 'critical',
          },
        },
      ],
    });

    expect(snapshot.testRuns, hasLength(1));
    expect(snapshot.testRuns.single.title, 'Complete checkout');
    expect(snapshot.testRuns.single.priority, 'critical');
  });
}
