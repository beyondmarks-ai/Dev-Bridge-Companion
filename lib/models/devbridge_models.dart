class PairingPayload {
  const PairingPayload({
    required this.baseUri,
    required this.sessionId,
    required this.pairingToken,
  });

  final Uri baseUri;
  final String sessionId;
  final String pairingToken;

  static PairingPayload? tryParse(String rawValue) {
    final uri = Uri.tryParse(rawValue.trim());
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (uri.scheme == 'http' && !_isPrivateHost(uri.host)) return null;
    if (!uri.path.endsWith('/pair.html')) return null;

    final sessionId = uri.queryParameters['session'];
    final token = uri.queryParameters['token'];
    if (sessionId == null ||
        !_uuid.hasMatch(sessionId) ||
        token == null ||
        token.length < 32) {
      return null;
    }

    return PairingPayload(
      baseUri: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ),
      sessionId: sessionId,
      pairingToken: token,
    );
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool _isPrivateHost(String host) {
    if (host == 'localhost' || host == '10.0.2.2') return true;
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final values = parts.cast<int>();
    if (values.any((part) => part < 0 || part > 255)) return false;
    return values[0] == 10 ||
        (values[0] == 172 && values[1] >= 16 && values[1] <= 31) ||
        (values[0] == 192 && values[1] == 168) ||
        values[0] == 127;
  }
}

class ConnectionCredentials {
  const ConnectionCredentials({
    required this.baseUri,
    required this.sessionId,
    required this.deviceId,
    required this.deviceToken,
    required this.deviceName,
  });

  final Uri baseUri;
  final String sessionId;
  final String deviceId;
  final String deviceToken;
  final String deviceName;
}

class DevBridgeBuild {
  const DevBridgeBuild({
    required this.id,
    required this.versionName,
    required this.versionCode,
    required this.sizeBytes,
    required this.sha256,
  });

  final String id;
  final String versionName;
  final int versionCode;
  final int sizeBytes;
  final String sha256;

  factory DevBridgeBuild.fromJson(Map<String, dynamic> json) => DevBridgeBuild(
    id: json['buildId'] as String,
    versionName: json['versionName'] as String,
    versionCode: json['versionCode'] as int,
    sizeBytes: json['sizeBytes'] as int,
    sha256: json['sha256'] as String,
  );
}

class SessionSnapshot {
  const SessionSnapshot({
    required this.projectName,
    required this.appName,
    required this.packageName,
    required this.expiresAt,
    required this.builds,
  });

  final String projectName;
  final String appName;
  final String? packageName;
  final DateTime expiresAt;
  final List<DevBridgeBuild> builds;

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) =>
      SessionSnapshot(
        projectName: json['projectName'] as String,
        appName: (json['appName'] as String?) ?? json['projectName'] as String,
        packageName: json['packageName'] as String?,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        builds: (json['builds'] as List<dynamic>)
            .map(
              (item) => DevBridgeBuild.fromJson(item as Map<String, dynamic>),
            )
            .toList(growable: false),
      );
}
