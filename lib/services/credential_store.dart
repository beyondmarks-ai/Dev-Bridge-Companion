import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/devbridge_models.dart';

class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _baseUri = 'connection.baseUri';
  static const _sessionId = 'connection.sessionId';
  static const _deviceId = 'connection.deviceId';
  static const _deviceToken = 'connection.deviceToken';
  static const _deviceName = 'connection.deviceName';

  Future<void> save(ConnectionCredentials value) async {
    await Future.wait([
      _storage.write(key: _baseUri, value: value.baseUri.toString()),
      _storage.write(key: _sessionId, value: value.sessionId),
      _storage.write(key: _deviceId, value: value.deviceId),
      _storage.write(key: _deviceToken, value: value.deviceToken),
      _storage.write(key: _deviceName, value: value.deviceName),
    ]);
  }

  Future<ConnectionCredentials?> read() async {
    final values = await Future.wait([
      _storage.read(key: _baseUri),
      _storage.read(key: _sessionId),
      _storage.read(key: _deviceId),
      _storage.read(key: _deviceToken),
      _storage.read(key: _deviceName),
    ]);
    if (values.any((value) => value == null)) return null;
    return ConnectionCredentials(
      baseUri: Uri.parse(values[0]!),
      sessionId: values[1]!,
      deviceId: values[2]!,
      deviceToken: values[3]!,
      deviceName: values[4]!,
    );
  }

  Future<void> clear() => _storage.deleteAll();
}
