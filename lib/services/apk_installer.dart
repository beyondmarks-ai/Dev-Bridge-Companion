import 'dart:io';

import 'package:flutter/services.dart';

enum InstallLaunchResult { started, permissionRequired }

class ApkInstaller {
  static const _channel = MethodChannel('devbridge/apk_installer');

  Future<InstallLaunchResult> install(File apk) async {
    final result = await _channel.invokeMethod<String>('installApk', {
      'path': apk.path,
    });
    return result == 'permission_required'
        ? InstallLaunchResult.permissionRequired
        : InstallLaunchResult.started;
  }
}
