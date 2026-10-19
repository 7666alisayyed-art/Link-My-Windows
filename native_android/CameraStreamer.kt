package com.linkmywindows.link_my_windows

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import java.io.ByteArrayOutputStream

/**
 * Streams the back camera as JPEG frames (up to about 30 per second, 720p at most)
 * straight from Camera2, so it is much faster than taking pictures.
 */
class CameraStreamer(
    private val context: Context,
    private val onFrame: (ByteArray) -> Unit
) {
    var rotation = 90
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var last = 0L

    @Volatile
    private var stopped = false

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun start(): Boolean {
        try {
            val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val ids = mgr.cameraIdList
            val id = ids.firstOrNull {
                mgr.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: ids.firstOrNull() ?: return false
            val ch = mgr.getCameraCharacteristics(id)
            rotation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return false
            val sizes = map.getOutputSizes(ImageFormat.YUV_420_888) ?: return false
            val size = sizes.filter { it.width <= 1280 && it.height <= 720 }
                .maxByOrNull { it.width * it.height }
                ?: sizes.minByOrNull { it.width * it.height }
                ?: return false

            val t = HandlerThread("lmw-camera")
            t.start()
            thread = t
            val handler = Handler(t.looper)

            val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 3)
            reader = r
            r.setOnImageAvailableListener({ rd ->
                val img = try {
                    rd.acquireLatestImage()
                } catch (e: Exception) {
                    null
                }
                if (img != null) {
                    try {
                        if (!stopped) handleImage(img)
                    } finally {
                        img.close()
                    }
                }
            }, handler)

            mgr.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (stopped) {
                        camera.close()
                        return
                    }
                    device = camera
                    try {
                        val surface = r.surface
                        camera.createCaptureSession(
                            listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(s: CameraCaptureSession) {
                                    if (stopped) {
                                        s.close()
                                        return
                                    }
                                    session = s
                                    try {
                                        val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                        req.addTarget(surface)
                                        req.set(
                                            CaptureRequest.CONTROL_AF_MODE,
                                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                                        )
                                        s.setRepeatingRequest(req.build(), null, handler)
                                    } catch (e: Exception) {
                                        stop()
                                    }
                                }

                                override fun onConfigureFailed(s: CameraCaptureSession) {
                                    stop()
                                }
                            },
                            handler
                        )
                    } catch (e: Exception) {
                        stop()
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    stop()
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    stop()
                }
            }, handler)
            return true
        } catch (e: Exception) {
            stop()
            return false
        }
    }

    private fun handleImage(img: Image) {
        val now = SystemClock.elapsedRealtime()
        if (now - last < 30) return
        last = now

        val w = img.width
        val h = img.height
        val nv21 = ByteArray(w * h * 3 / 2)

        val yPlane = img.planes[0]
        val yBuf = yPlane.buffer
        val yRow = yPlane.rowStride
        var pos = 0
        for (r in 0 until h) {
            yBuf.position(r * yRow)
            yBuf.get(nv21, pos, w)
            pos += w
        }

        val uPlane = img.planes[1]
        val vPlane = img.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val uRow = uPlane.rowStride
        val uPix = uPlane.pixelStride
        val vRow = vPlane.rowStride
        val vPix = vPlane.pixelStride
        for (r in 0 until h / 2) {
            for (c in 0 until w / 2) {
                nv21[pos++] = vBuf.get(r * vRow + c * vPix)
                nv21[pos++] = uBuf.get(r * uRow + c * uPix)
            }
        }

        val out = ByteArrayOutputStream(64 * 1024)
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), 60, out)
        onFrame(out.toByteArray())
    }

    fun stop() {
        stopped = true
        try {
            session?.close()
        } catch (e: Exception) {
        }
        try {
            device?.close()
        } catch (e: Exception) {
        }
        try {
            reader?.close()
        } catch (e: Exception) {
        }
        session = null
        device = null
        reader = null
        thread?.quitSafely()
        thread = null
    }
}
