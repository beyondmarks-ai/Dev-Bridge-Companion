package com.example.dev_bridge

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap

class MainActivity : FlutterActivity() {
    private val pendingInstalls = ConcurrentHashMap<Int, MethodChannel.Result>()

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val filter = IntentFilter(INSTALL_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(installReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(installReceiver, filter)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call.argument("path"), result)
                    "launchPackage" -> launchPackage(call.argument("packageName"), result)
                    else -> result.notImplemented()
                }
            }
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

    private fun launchPackage(targetPackage: String?, result: MethodChannel.Result) {
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
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
        pendingInstalls.values.forEach { it.error("activity_destroyed", "DevBridge closed before installation completed.", null) }
        pendingInstalls.clear()
        super.onDestroy()
    }

    private companion object {
        const val INSTALLER_CHANNEL = "devbridge/apk_installer"
        const val INSTALL_ACTION = "com.example.dev_bridge.INSTALL_RESULT"
    }
}
