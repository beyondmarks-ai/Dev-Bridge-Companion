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
}
