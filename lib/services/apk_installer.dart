import 'dart:io';

import 'package:flutter/services.dart';

class InstallResult {
  const InstallResult({
    required this.status,
    required this.message,
    this.statusCode,
    this.packageName,
    this.details,
  });

  final String status;
  final String message;
  final int? statusCode;
  final String? packageName;
  final String? details;

  bool get succeeded => status == 'success';

  factory InstallResult.fromMap(Map<Object?, Object?> value) => InstallResult(
    status: value['status'] as String? ?? 'failure',
    message:
        value['message'] as String? ??
        'Android did not return an installation result.',
    statusCode: value['statusCode'] as int?,
    packageName: value['packageName'] as String?,
    details: value['details'] as String?,
  );
}

class ApkInstaller {
  static const _channel = MethodChannel('devbridge/apk_installer');

  Future<InstallResult> install(File apk) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'installApk',
      {'path': apk.path},
    );
    return InstallResult.fromMap(result ?? const {});
  }

  Future<InstallResult> launch({
    required String packageName,
    required Uri baseUri,
    required String handoffToken,
    String? captureId,
  }) async {
    final result = await _channel
        .invokeMethod<Map<Object?, Object?>>('launchPackage', {
          'packageName': packageName,
          'baseUrl': baseUri.toString(),
          'handoffToken': handoffToken,
          'captureId': captureId,
        });
    return InstallResult.fromMap(result ?? const {});
  }
}
