package com.example.dev_bridge

import android.app.PendingIntent
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.graphics.Bitmap
import android.media.projection.MediaProjectionManager
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

class MainActivity : FlutterActivity() {
    private val pendingInstalls = ConcurrentHashMap<Int, MethodChannel.Result>()
    private var recordingStartResult: MethodChannel.Result? = null
    private var recordingStopResult: MethodChannel.Result? = null
    private var recordingPath: String? = null

    private val installReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
            val result = pendingInstalls[sessionId] ?: return
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT) as? Intent
                }
                if (confirmation == null) {
                    finishInstall(sessionId, result, status, "user_action_unavailable", "Android did not provide an installation confirmation screen.", message)
                } else {
                    confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(confirmation)
                }
                return
            }
            finishInstall(sessionId, result, status, statusName(status), friendlyMessage(status, message), message)
        }
    }

    private val recordingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getStringExtra("status")
            val path = intent.getStringExtra("path")
            val error = intent.getStringExtra("error")
            val response = mapOf("status" to status, "path" to path, "error" to error)
            when (status) {
                "recording_started" -> {
                    recordingStartResult?.success(response)
                    recordingStartResult = null
                }
                "recording_stopped" -> {
                    val pending = recordingStopResult
                    recordingStopResult = null
                    recordingPath = null
                    Thread {
                        val frames = path?.let(::extractVideoFrames).orEmpty()
                        runOnUiThread {
                            pending?.success(response + ("framePaths" to frames))
                        }
                    }.start()
                }
                "recording_failed" -> {
                    recordingStartResult?.success(response)
                    recordingStopResult?.success(response)
                    recordingStartResult = null
                    recordingStopResult = null
                    recordingPath = null
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val filter = IntentFilter(INSTALL_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(installReceiver, filter, RECEIVER_NOT_EXPORTED)
            registerReceiver(recordingReceiver, IntentFilter(ScreenRecordingService.STATUS_ACTION), RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(installReceiver, filter)
            registerReceiver(recordingReceiver, IntentFilter(ScreenRecordingService.STATUS_ACTION))
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call.argument("path"), result)
                    "launchPackage" -> launchPackage(
                        call.argument("packageName"),
                        call.argument("baseUrl"),
                        call.argument("handoffToken"),
                        call.argument("captureId"),
                        result,
                    )
                    "startScreenRecording" -> startScreenRecording(result)
                    "stopScreenRecording" -> stopScreenRecording(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startScreenRecording(result: MethodChannel.Result) {
        if (recordingStartResult != null) {
            result.error("recording_busy", "A recording request is already active.", null)
            return
        }
        recordingStartResult = result
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST)
    }

    private fun stopScreenRecording(result: MethodChannel.Result) {
        if (recordingPath == null) {
            result.success(mapOf("status" to "not_recording", "error" to "No recording is active."))
            return
        }
        recordingStopResult = result
        startService(Intent(this, ScreenRecordingService::class.java).setAction(ScreenRecordingService.ACTION_STOP))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SCREEN_CAPTURE_REQUEST) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            recordingStartResult?.success(mapOf("status" to "permission_denied", "error" to "Screen recording permission was not granted."))
            recordingStartResult = null
            return
        }
        val metrics = resources.displayMetrics
        val output = File(cacheDir, "devbridge-recording-${System.currentTimeMillis()}.mp4")
        recordingPath = output.absolutePath
        val service = Intent(this, ScreenRecordingService::class.java).apply {
            action = ScreenRecordingService.ACTION_START
            putExtra(ScreenRecordingService.EXTRA_RESULT_DATA, data)
            putExtra(ScreenRecordingService.EXTRA_WIDTH, metrics.widthPixels)
            putExtra(ScreenRecordingService.EXTRA_HEIGHT, metrics.heightPixels)
            putExtra(ScreenRecordingService.EXTRA_DENSITY, metrics.densityDpi)
            putExtra(ScreenRecordingService.EXTRA_OUTPUT_PATH, output.absolutePath)
        }
        ContextCompat.startForegroundService(this, service)
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("missing_path", "APK path is required.", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            result.success(resultMap("permission_required", "Enable Allow from this source, then return and try again.", null, null, null))
            return
        }
        val apk = File(path)
        if (!apk.isFile) {
            result.success(resultMap("missing_file", "The downloaded APK no longer exists.", null, null, null))
            return
        }

        val targetPackage = packageManager.getPackageArchiveInfo(apk.absolutePath, 0)?.packageName
        var session: PackageInstaller.Session? = null
        try {
            val parameters = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                targetPackage?.let(::setAppPackageName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
                }
            }
            val sessionId = packageManager.packageInstaller.createSession(parameters)
            session = packageManager.packageInstaller.openSession(sessionId)
            FileInputStream(apk).use { input ->
                session.openWrite("base.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            pendingInstalls[sessionId] = result
            val callback = Intent(INSTALL_ACTION).setPackage(packageName).putExtra(PackageInstaller.EXTRA_SESSION_ID, sessionId)
            val pending = PendingIntent.getBroadcast(
                this,
                sessionId,
                callback,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(pending.intentSender)
        } catch (exception: Exception) {
            session?.abandon()
            result.success(resultMap("installer_error", "Could not stage the APK for installation.", null, targetPackage, exception.message))
        } finally {
            session?.close()
        }
    }

    private fun launchPackage(targetPackage: String?, baseUrl: String?, handoffToken: String?, captureId: String?, result: MethodChannel.Result) {
        if (targetPackage.isNullOrBlank()) {
            result.success(resultMap("package_unknown", "The session does not specify an application package name.", null, null, null))
            return
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(targetPackage)
        if (launchIntent == null) {
            result.success(resultMap("not_launchable", "Android could not find a launchable activity for $targetPackage.", null, targetPackage, null))
            return
        }
        try {
            launchIntent.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra("devbridge.baseUrl", baseUrl)
                putExtra("devbridge.handoffToken", handoffToken)
                captureId?.let { putExtra("devbridge.captureId", it) }
            }
            startActivity(launchIntent)
            result.success(resultMap("launch_requested", "Application launch requested.", null, targetPackage, null))
        } catch (exception: Exception) {
            result.success(resultMap("launch_failed", "Android rejected the application launch.", null, targetPackage, exception.message))
        }
    }

    private fun finishInstall(sessionId: Int, result: MethodChannel.Result, statusCode: Int, status: String, message: String, details: String?) {
        pendingInstalls.remove(sessionId)
        val packageName = packageManager.packageInstaller.getSessionInfo(sessionId)?.appPackageName
        result.success(resultMap(status, message, statusCode, packageName, details))
    }

    private fun extractVideoFrames(path: String): List<String> {
        val video = File(path)
        if (!video.isFile) return emptyList()
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(video.absolutePath)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ?: return emptyList()
            listOf(0.05, 0.35, 0.65, 0.90).mapIndexedNotNull { index, fraction ->
                val frame = retriever.getFrameAtTime(
                    (durationMs * 1000 * fraction).toLong(),
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                ) ?: return@mapIndexedNotNull null
                val width = minOf(720, frame.width)
                val height = (frame.height * (width.toDouble() / frame.width)).toInt().coerceAtLeast(2)
                val scaled = if (width == frame.width) frame else Bitmap.createScaledBitmap(frame, width, height, true)
                val output = File(cacheDir, "devbridge-frame-${System.currentTimeMillis()}-$index.jpg")
                FileOutputStream(output).use { scaled.compress(Bitmap.CompressFormat.JPEG, 82, it) }
                if (scaled !== frame) scaled.recycle()
                frame.recycle()
                output.absolutePath
            }
        } catch (_: Exception) {
            emptyList()
        } finally {
            retriever.release()
        }
    }

    private fun resultMap(status: String, message: String, statusCode: Int?, packageName: String?, details: String?) = mapOf(
        "status" to status,
        "message" to message,
        "statusCode" to statusCode,
        "packageName" to packageName,
        "details" to details,
    )

    private fun statusName(status: Int) = when (status) {
        PackageInstaller.STATUS_SUCCESS -> "success"
        PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "conflict"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
        PackageInstaller.STATUS_FAILURE_INVALID -> "invalid_apk"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "insufficient_storage"
        PackageInstaller.STATUS_FAILURE_TIMEOUT -> "timeout"
        else -> "failure"
    }

    private fun friendlyMessage(status: Int, fallback: String) = when (status) {
        PackageInstaller.STATUS_SUCCESS -> "APK installed successfully."
        PackageInstaller.STATUS_FAILURE_ABORTED -> "Installation was cancelled."
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Installation was blocked by Android security or device policy."
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "Installation conflicts with an existing package or signing certificate."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "This APK is incompatible with the device."
        PackageInstaller.STATUS_FAILURE_INVALID -> "Android rejected the APK as invalid or incorrectly signed."
        PackageInstaller.STATUS_FAILURE_STORAGE -> "The device does not have enough available storage."
        PackageInstaller.STATUS_FAILURE_TIMEOUT -> "The Android package installer timed out."
        else -> fallback.ifBlank { "Android could not install the APK." }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(installReceiver) }
        runCatching { unregisterReceiver(recordingReceiver) }
        pendingInstalls.values.forEach { it.error("activity_destroyed", "DevBridge closed before installation completed.", null) }
        pendingInstalls.clear()
        super.onDestroy()
    }

    private companion object {
        const val INSTALLER_CHANNEL = "devbridge/apk_installer"
        const val INSTALL_ACTION = "com.example.dev_bridge.INSTALL_RESULT"
        const val SCREEN_CAPTURE_REQUEST = 7310
    }
}
