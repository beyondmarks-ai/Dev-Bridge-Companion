package ai.beyondmarks.devbridge.diagnostics

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DevBridgeDiagnosticsPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLaunchHandoff" -> result.success(readHandoff())
            "getHistoricalExitReasons" -> result.success(readHistoricalExits())
            else -> result.notImplemented()
        }
    }

    private fun readHandoff(): Map<String, String>? {
        val intent = activity?.intent ?: return null
        val baseUrl = intent.getStringExtra(BASE_URL) ?: return null
        val token = intent.getStringExtra(HANDOFF_TOKEN) ?: return null
        intent.removeExtra(BASE_URL)
        intent.removeExtra(HANDOFF_TOKEN)
        return mapOf("baseUrl" to baseUrl, "handoffToken" to token)
    }

    private fun readHistoricalExits(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val lastTimestamp = preferences.getLong(LAST_EXIT_TIMESTAMP, 0)
        val exits = manager.getHistoricalProcessExitReasons(null, 0, 20)
            .filter { it.timestamp > lastTimestamp }
            .sortedBy { it.timestamp }
        if (exits.isNotEmpty()) preferences.edit().putLong(LAST_EXIT_TIMESTAMP, exits.maxOf { it.timestamp }).apply()
        return exits.map { exit ->
            val traceBytes = runCatching { exit.traceInputStream?.use { it.readNBytes(MAX_TRACE_BYTES) } }.getOrNull()
            val nativeTrace = exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE
            mapOf(
                "reason" to reasonName(exit.reason),
                "reasonCode" to exit.reason,
                "status" to exit.status,
                "description" to exit.description,
                "importance" to exit.importance,
                "pssKb" to exit.pss,
                "rssKb" to exit.rss,
                "timestamp" to exit.timestamp,
                "trace" to traceBytes?.let {
                    if (nativeTrace) Base64.encodeToString(it, Base64.NO_WRAP) else it.toString(Charsets.UTF_8)
                },
                "traceEncoding" to if (nativeTrace && traceBytes != null) "base64-protobuf" else "text",
            )
        }
    }

    private fun reasonName(reason: Int) = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "java_crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        else -> "other_$reason"
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val CHANNEL = "devbridge/diagnostics"
        const val BASE_URL = "devbridge.baseUrl"
        const val HANDOFF_TOKEN = "devbridge.handoffToken"
        const val PREFERENCES = "devbridge_diagnostics"
        const val LAST_EXIT_TIMESTAMP = "last_exit_timestamp"
        const val MAX_TRACE_BYTES = 64 * 1024
    }
}
