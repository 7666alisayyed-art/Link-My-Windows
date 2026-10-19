package com.linkmywindows.link_my_windows

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity() {
    private val screenRequest = 4711
    private val cameraRequest = 4712

    private var pendingScreen: MethodChannel.Result? = null
    private var pendingCamera: MethodChannel.Result? = null

    @Volatile
    private var pendingShare: Map<String, Any?>? = null

    private var screenSink: EventChannel.EventSink? = null
    private var camSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val screenFrame = AtomicReference<ByteArray?>(null)
    private val camFrame = AtomicReference<ByteArray?>(null)
    private var streamer: CameraStreamer? = null

    /** Sends only the newest frame to Dart; older frames that were not sent yet are dropped. */
    private fun push(
        ref: AtomicReference<ByteArray?>,
        sink: () -> EventChannel.EventSink?,
        bytes: ByteArray
    ) {
        if (ref.getAndSet(bytes) == null) {
            main.post {
                val f = ref.getAndSet(null)
                if (f != null) sink()?.success(f)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        ScreenHolder.onFrame = { bytes -> push(screenFrame, { screenSink }, bytes) }

        EventChannel(messenger, "lmw/screen_frames").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    screenSink = events
                }

                override fun onCancel(arguments: Any?) {
                    screenSink = null
                }
            }
        )
        EventChannel(messenger, "lmw/cam_frames").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    camSink = events
                }

                override fun onCancel(arguments: Any?) {
                    camSink = null
                }
            }
        )

        MethodChannel(messenger, "lmw/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "startScreen" -> {
                    if (pendingScreen != null) {
                        result.success(false)
                    } else {
                        pendingScreen = result
                        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        startActivityForResult(mgr.createScreenCaptureIntent(), screenRequest)
                    }
                }
                "stopScreen" -> {
                    stopService(Intent(this, ScreenService::class.java))
                    ScreenHolder.frame = null
                    result.success(true)
                }
                "startCamera" -> {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(beginCamera())
                    } else {
                        pendingCamera = result
                        ActivityCompat.requestPermissions(
                            this, arrayOf(Manifest.permission.CAMERA), cameraRequest
                        )
                    }
                }
                "stopCamera" -> {
                    streamer?.stop()
                    streamer = null
                    result.success(true)
                }
                "takeShare" -> {
                    val s = pendingShare
                    pendingShare = null
                    result.success(s)
                }
                "controlEnabled" -> result.success(ControlService.instance != null)
                "openAccessibility" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                "control" -> {
                    val svc = ControlService.instance
                    if (svc == null) {
                        result.success(false)
                    } else {
                        val dm = resources.displayMetrics
                        val w = dm.widthPixels.toFloat()
                        val h = dm.heightPixels.toFloat()
                        val x1 = (call.argument<Double>("x1") ?: call.argument<Double>("x") ?: 0.0).toFloat() * w
                        val y1 = (call.argument<Double>("y1") ?: call.argument<Double>("y") ?: 0.0).toFloat() * h
                        val x2 = (call.argument<Double>("x2") ?: call.argument<Double>("x") ?: 0.0).toFloat() * w
                        val y2 = (call.argument<Double>("y2") ?: call.argument<Double>("y") ?: 0.0).toFloat() * h
                        val ms = (call.argument<Int>("ms") ?: 60).toLong()
                        when (call.argument<String>("t")) {
                            "tap" -> svc.swipe(x1, y1, x1, y1, 50)
                            "swipe" -> svc.swipe(x1, y1, x2, y2, ms)
                            "key" -> svc.key(call.argument<String>("k") ?: "")
                            "text" -> svc.typeText(call.argument<String>("s") ?: "")
                            "bs" -> svc.backspace()
                            "enter" -> svc.enter()
                        }
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Starts the camera; returns the rotation in degrees, or -1 if it could not start. */
    private fun beginCamera(): Int {
        streamer?.stop()
        val s = CameraStreamer(this) { bytes -> push(camFrame, { camSink }, bytes) }
        if (!s.start()) return -1
        streamer = s
        return s.rotation
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == cameraRequest) {
            val res = pendingCamera
            pendingCamera = null
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            res?.success(if (granted) beginCamera() else -1)
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        if (code == screenRequest) {
            val res = pendingScreen
            pendingScreen = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                ScreenHolder.resultCode = resultCode
                ScreenHolder.data = data
                val i = Intent(this, ScreenService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(i)
                } else {
                    startService(i)
                }
                res?.success(true)
            } else {
                res?.success(false)
            }
            return
        }
        super.onActivityResult(code, resultCode, data)
    }

    /** Handles "Share > Link my Windows" from other apps (text or one file). */
    @Suppress("DEPRECATION")
    private fun handleShare(i: Intent?) {
        if (i == null || i.action != Intent.ACTION_SEND) return
        val text = i.getStringExtra(Intent.EXTRA_TEXT)
        val uri = i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (uri != null) {
            Thread {
                try {
                    var name = "shared-file"
                    contentResolver.query(uri, null, null, null, null)?.use { c ->
                        val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0 && c.moveToFirst()) {
                            name = c.getString(idx) ?: name
                        }
                    }
                    name = name.substringAfterLast('/')
                    val out = File(cacheDir, name)
                    contentResolver.openInputStream(uri)?.use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    }
                    pendingShare = mapOf(
                        "type" to "file",
                        "path" to out.absolutePath,
                        "name" to name
                    )
                } catch (e: Exception) {
                }
            }.start()
        } else if (text != null) {
            pendingShare = mapOf("type" to "text", "text" to text)
        }
    }
}
