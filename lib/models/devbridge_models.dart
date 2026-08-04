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
    required this.testRuns,
  });

  final String projectName;
  final String appName;
  final String? packageName;
  final DateTime expiresAt;
  final List<DevBridgeBuild> builds;
  final List<GuidedTestRun> testRuns;

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
        testRuns: ((json['testRuns'] as List<dynamic>?) ?? const [])
            .map((item) => GuidedTestRun.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
      );
}

class GuidedTestRun {
  const GuidedTestRun({
    required this.id,
    required this.testCaseId,
    required this.title,
    required this.instructions,
    required this.expectedResult,
    required this.priority,
    required this.status,
    required this.buildId,
    required this.captureId,
  });

  final String id;
  final String testCaseId;
  final String title;
  final String instructions;
  final String expectedResult;
  final String priority;
  final String status;
  final String? buildId;
  final String? captureId;

  factory GuidedTestRun.fromJson(Map<String, dynamic> json) {
    final testCase = json['testCase'] as Map<String, dynamic>? ?? const {};
    return GuidedTestRun(
      id: json['id'] as String,
      testCaseId: json['testCaseId'] as String,
      title: testCase['title'] as String? ?? 'Guided test',
      instructions: testCase['instructions'] as String? ?? '',
      expectedResult: testCase['expectedResult'] as String? ?? '',
      priority: testCase['priority'] as String? ?? 'normal',
      status: json['status'] as String? ?? 'ready',
      buildId: json['buildId'] as String?,
      captureId: json['captureId'] as String?,
    );
  }
}

class AiDiagnosis {
  const AiDiagnosis({
    required this.summary,
    required this.problemLocation,
    required this.suggestedFix,
    required this.confidence,
  });

  final String summary;
  final String problemLocation;
  final String suggestedFix;
  final int confidence;

  factory AiDiagnosis.fromJson(Map<String, dynamic> json) => AiDiagnosis(
    summary: json['summary'] as String,
    problemLocation: json['problemLocation'] as String,
    suggestedFix: json['suggestedFix'] as String,
    confidence: json['confidence'] as int,
  );
}

class TestCompletionResult {
  const TestCompletionResult({this.analysis, this.analysisMessage});
  final AiDiagnosis? analysis;
  final String? analysisMessage;
}

class SdkHandoff {
  const SdkHandoff({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;
}
