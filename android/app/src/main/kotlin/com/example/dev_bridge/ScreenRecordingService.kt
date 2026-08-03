package com.example.dev_bridge

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File

class ScreenRecordingService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var recorder: MediaRecorder? = null
    private var outputPath: String? = null
    private var stopping = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRecording(intent)
            ACTION_STOP -> stopRecording(true)
        }
        return START_NOT_STICKY
    }

    private fun startRecording(intent: Intent) {
        createNotificationChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("DevBridge test recording")
            .setContentText("Your screen is being recorded with your permission.")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA) as? Intent
        }
        if (resultData == null) {
            sendStatus("recording_failed", null, "Android did not return screen-capture permission data.")
            stopSelf()
            return
        }

        try {
            val width = intent.getIntExtra(EXTRA_WIDTH, 720).coerceAtLeast(2).let { it - it % 2 }
            val height = intent.getIntExtra(EXTRA_HEIGHT, 1280).coerceAtLeast(2).let { it - it % 2 }
            val density = intent.getIntExtra(EXTRA_DENSITY, 320)
            outputPath = intent.getStringExtra(EXTRA_OUTPUT_PATH)
            val mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            recorder = mediaRecorder.apply {
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setVideoSize(width, height)
                setVideoFrameRate(30)
                setVideoEncodingBitRate(8_000_000)
                setOutputFile(outputPath)
                prepare()
            }
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val activeProjection = manager.getMediaProjection(Activity.RESULT_OK, resultData)
                ?: throw IllegalStateException("Android did not create a MediaProjection session.")
            projection = activeProjection
            activeProjection.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() { stopRecording(false) }
                }, null)
            display = activeProjection.createVirtualDisplay(
                "DevBridgeRecording", width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                mediaRecorder.surface, null, null,
            )
            mediaRecorder.start()
            sendStatus("recording_started", outputPath, null)
        } catch (exception: Exception) {
            sendStatus("recording_failed", outputPath, exception.message)
            stopRecording(false)
        }
    }

    private fun stopRecording(stopProjection: Boolean) {
        if (stopping) return
        stopping = true
        runCatching { recorder?.stop() }
        runCatching { recorder?.reset() }
        runCatching { recorder?.release() }
        recorder = null
        display?.release()
        display = null
        if (stopProjection) runCatching { projection?.stop() }
        projection = null
        val path = outputPath
        val validPath = path?.takeIf { File(it).isFile && File(it).length() > 0 }
        sendStatus(if (validPath != null) "recording_stopped" else "recording_failed", validPath,
            if (validPath == null) "The screen recording did not produce a playable file." else null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun sendStatus(status: String, path: String?, error: String?) {
        sendBroadcast(Intent(STATUS_ACTION).setPackage(packageName).apply {
            putExtra("status", status)
            putExtra("path", path)
            putExtra("error", error)
        })
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "DevBridge screen recording", NotificationManager.IMPORTANCE_LOW,
        ))
    }

    companion object {
        const val ACTION_START = "com.example.dev_bridge.RECORDING_START"
        const val ACTION_STOP = "com.example.dev_bridge.RECORDING_STOP"
        const val STATUS_ACTION = "com.example.dev_bridge.RECORDING_STATUS"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_DENSITY = "density"
        const val EXTRA_OUTPUT_PATH = "outputPath"
        private const val CHANNEL_ID = "devbridge_recording"
        private const val NOTIFICATION_ID = 3107
    }
}
