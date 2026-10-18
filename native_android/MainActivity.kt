package com.linkmywindows.link_my_windows

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "lmw/native"
    private val requestCode = 4711
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startScreen" -> {
                        if (pending != null) {
                            result.success(false)
                        } else {
                            pending = result
                            val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                            startActivityForResult(mgr.createScreenCaptureIntent(), requestCode)
                        }
                    }
                    "stopScreen" -> {
                        stopService(Intent(this, ScreenService::class.java))
                        ScreenHolder.frame = null
                        result.success(true)
                    }
                    "getScreenFrame" -> result.success(ScreenHolder.frame)
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        if (code == requestCode) {
            val res = pending
            pending = null
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
}
