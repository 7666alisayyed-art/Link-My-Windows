package com.linkmywindows.link_my_windows

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import java.io.ByteArrayOutputStream

object ScreenHolder {
    @Volatile
    var frame: ByteArray? = null
    var resultCode: Int = 0
    var data: Intent? = null
}

class ScreenService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var lastFrameAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        startCapture()
        return START_NOT_STICKY
    }

    private fun startForegroundCompat() {
        val channelId = "lmw_screen"
        val builder: Notification.Builder
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
            )
            builder = Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            builder = Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Link my Windows")
            .setContentText("Sharing your screen with your PC")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(1, notification)
        }
    }

    private fun startCapture() {
        val data = ScreenHolder.data
        if (data == null) {
            stopSelf()
            return
        }
        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mgr.getMediaProjection(ScreenHolder.resultCode, data)
        projection = p
        if (p == null) {
stopSelf()
return
        }

        val t = HandlerThread("lmw-capture")
        t.start()
        thread = t
        val handler = Handler(t.looper)

        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, handler)

        val dm = resources.displayMetrics
        val w = dm.widthPixels / 2
        val h = dm.heightPixels / 2
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = r
        display = p.createVirtualDisplay(
            "lmw", w, h, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            r.surface, null, handler
        )

        r.setOnImageAvailableListener({ rd ->
            val img = try {
                rd.acquireLatestImage()
            } catch (e: Exception) {
                null
            }
            if (img != null) {
                try {
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastFrameAt >= 100) {
                        lastFrameAt = now
                        val plane = img.planes[0]
                        val pixelStride = plane.pixelStride
                        val rowPadding = plane.rowStride - pixelStride * w
                        val full = Bitmap.createBitmap(
                            w + rowPadding / pixelStride, h, Bitmap.Config.ARGB_8888
                        )
                        full.copyPixelsFromBuffer(plane.buffer)
                        val bmp = if (rowPadding > 0) Bitmap.createBitmap(full, 0, 0, w, h) else full
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 55, out)
                        ScreenHolder.frame = out.toByteArray()
                        if (bmp !== full) bmp.recycle()
                        full.recycle()
                    }
                } finally {
                    img.close()
                }
            }
        }, handler)
    }

    override fun onDestroy() {
        display?.release()
        display = null
        reader?.close()
        reader = null
        try {
            projection?.stop()
        } catch (e: Exception) {
        }
        projection = null
        thread?.quitSafely()
        thread = null
        ScreenHolder.frame = null
        ScreenHolder.data = null
        super.onDestroy()
    }
}
