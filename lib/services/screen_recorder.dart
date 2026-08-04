import 'dart:io';

import 'package:flutter/services.dart';

class RecordingResult {
  const RecordingResult({
    required this.status,
    this.path,
    this.framePaths = const [],
    this.error,
  });
  final String status;
  final String? path;
  final List<String> framePaths;
  final String? error;

  factory RecordingResult.fromMap(Map<Object?, Object?> value) =>
      RecordingResult(
        status: value['status'] as String? ?? 'recording_failed',
        path: value['path'] as String?,
        framePaths:
            (value['framePaths'] as List<Object?>?)?.whereType<String>().toList(
              growable: false,
            ) ??
            const [],
        error: value['error'] as String?,
      );
}

class ScreenRecorder {
  static const _channel = MethodChannel('devbridge/apk_installer');

  Future<RecordingResult> start() async {
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'startScreenRecording',
    );
    return RecordingResult.fromMap(value ?? const {});
  }

  Future<(RecordingResult, File?)> stop() async {
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'stopScreenRecording',
    );
    final result = RecordingResult.fromMap(value ?? const {});
    final file = result.path == null ? null : File(result.path!);
    return (result, file);
  }
}
