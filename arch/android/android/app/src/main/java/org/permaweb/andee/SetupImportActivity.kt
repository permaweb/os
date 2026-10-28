package org.permaweb.andee

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executor
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/**
 * SCAN and "Open with your node": read a setup, show what it contains, and stage it only when the user says so.
 *
 * Sources: the camera (the PermawebOS extension's looping setup code), a JSON document opened or shared to
 * AndEE, or the [ACTION_IMPORT_CONFIG] action carrying a `config` (JSON), `config-b64` or `ur` extra, which
 * also makes setup scriptable:
 *
 *     adb shell am start -a org.permaweb.andee.action.IMPORT_CONFIG --es config-b64 <base64url of the JSON>
 *
 * Every source ends on the same review screen and the same [AndeeBootConfigStore.stageNextBootConfig] call as
 * the file picker; the splash's APPLY & CLOSE then commits it. Debug builds alone accept `--ez apply true` to
 * stage without the review, for unattended test setups.
 */
class SetupImportActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var overlay: SetupOverlay
    private var texture: TextureView? = null
    private var reviewText: String? = null

    private val scan = SetupScan()
    private val qr = QRCodeReader()
    private val hints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var scanning = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this).apply { setBackgroundColor(SetupOverlay.BACKGROUND) }
        overlay = SetupOverlay(this, object : SetupOverlay.Actions {
            override fun use() = useSetup()
            override fun back() = finish()
            override fun retry() = restartScan()
        })
        root.addView(overlay)
        setContentView(root)

        val incoming = try {
            readIncoming(intent)
        } catch (exc: Exception) {
            Log.w(TAG, "incoming setup unreadable", exc)
            overlay.showError("That setup could not be read.", exc.message ?: "", canRetry = false)
            return
        }
        when {
            incoming == null -> startScan()
            BuildConfig.DEBUG && intent.action == ACTION_IMPORT_CONFIG && intent.getBooleanExtra("apply", false) -> {
                reviewText = incoming
                useSetup()
            }
            else -> showReview(incoming)
        }
    }

    override fun onResume() {
        super.onResume()
        if (scanning && texture?.isAvailable == true) openCamera()
    }

    override fun onPause() {
        closeCamera()
        super.onPause()
    }

    override fun onDestroy() {
        cameraThread?.quitSafely()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ sources

    private fun readIncoming(i: Intent): String? = when (i.action) {
        ACTION_IMPORT_CONFIG -> i.getStringExtra("config")
            ?: i.getStringExtra("config-b64")?.let(SetupPayload::fromBase64)
            ?: i.getStringExtra("ur")?.let(SetupPayload::fromUrString)
            ?: i.data?.let(::readUri)
            ?: throw IllegalArgumentException("Send a config, config-b64 or ur extra.")
        Intent.ACTION_VIEW -> i.data?.let(::readUri)
        Intent.ACTION_SEND -> streamExtra(i)?.let(::readUri)
            ?: i.getStringExtra(Intent.EXTRA_TEXT)?.let { text ->
                if (text.trim().startsWith("ur:", ignoreCase = true)) SetupPayload.fromUrString(text) else text
            }
        else -> null
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(i: Intent): Uri? = i.getParcelableExtra(Intent.EXTRA_STREAM)

    private fun readUri(uri: Uri): String = contentResolver.openInputStream(uri)?.use { input ->
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            require(out.size() <= SetupPayload.MAX_CONFIG_BYTES) { "Setup is too large" }
        }
        out.toString(Charsets.UTF_8.name())
    } ?: throw IllegalArgumentException("The file could not be opened.")

    // ------------------------------------------------------------------ review and staging

    private fun showReview(text: String) {
        val rows = try {
            summarize(text)
        } catch (exc: Exception) {
            overlay.showError("That isn't a node setup.", "It must be one JSON object.", canRetry = scanning)
            return
        }
        reviewText = text
        overlay.showReview(rows)
    }

    private fun summarize(text: String): List<Pair<String, String>> {
        val config = JSONObject(text)
        val keys = config.keys().asSequence().toList()
        val providers = config.optJSONObject("inference-providers")
        val keyed = providers?.keys()?.asSequence()?.filter { name ->
            providers.optJSONObject(name)?.optJSONObject("priv")?.has("api-key") == true
        }?.toList().orEmpty()
        val operator = config.optString("operator").takeIf { it.length == 43 }
        return listOfNotNull(
            "PROFILE" to config.optString("andee-profile-source", "custom").substringAfter('/').ifBlank { "custom" },
            operator?.let { "OPERATOR" to "${it.take(6)}…${it.takeLast(6)}" },
            "SIZE" to "${text.toByteArray().size} B · ${keys.size} settings",
            "BUNDLER" to if (keys.any { it.startsWith("bundler-") }) "yes" else "no",
            // public access is the tunnel device, started from an `on` hook
            "TUNNEL" to if (text.contains("\"tunnel@")) "yes" else "no",
            "API KEY" to if (keyed.isEmpty()) "none" else keyed.joinToString(" · ") + " (hidden)",
        )
    }

    private fun useSetup() {
        val text = reviewText ?: return
        try {
            AndeeBootConfigStore.stageNextBootConfig(this, text)
        } catch (exc: Exception) {
            Log.w(TAG, "setup rejected", exc)
            overlay.showError("Your node can't use that setup.", "Check it in the configurator and try again.", canRetry = scanning)
            return
        }
        Toast.makeText(this, "Setup saved. Tap APPLY & CLOSE to start on it.", Toast.LENGTH_LONG).show()
        // back to the splash, where APPLY & CLOSE now waits, even when another app opened this import
        startActivity(
            Intent(this, OrnamentActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
        finish()
    }

    // ------------------------------------------------------------------ camera

    private fun startScan() {
        scanning = true
        overlay.showScanning()
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
            return
        }
        attachPreview()
    }

    private fun restartScan() {
        closeCamera()
        texture?.let(root::removeView)
        texture = null
        startScan()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CAMERA) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            attachPreview()
        } else {
            scanning = false
            overlay.showError("Camera access is off.", "Allow it in Settings to scan, or use LOAD JSON on the home screen.", canRetry = false)
        }
    }

    private fun attachPreview() {
        if (texture != null) return
        val view = TextureView(this)
        view.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) = openCamera()
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture) = true
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }
        root.addView(view, 0)
        texture = view
    }

    private fun handler(): Handler = cameraHandler ?: HandlerThread("AndEE-Setup-Scan").let { thread ->
        thread.start()
        cameraThread = thread
        Handler(thread.looper).also { cameraHandler = it }
    }

    private fun openCamera() {
        if (camera != null || !scanning) return
        val manager = getSystemService(CameraManager::class.java)
        try {
            val id = manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: manager.cameraIdList.firstOrNull()
            if (id == null) {
                overlay.showError("No camera is available.", "Use LOAD JSON on the home screen.", canRetry = false)
                return
            }
            val map = manager.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val size = map?.getOutputSizes(ImageFormat.YUV_420_888)
                ?.filter { it.width <= 1920 && it.height <= 1080 }
                ?.maxByOrNull { it.width * it.height } ?: Size(1280, 720)
            val handler = handler()
            reader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2).apply {
                setOnImageAvailableListener(::onFrame, handler)
            }
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    camera = device
                    startSession(device, size)
                }
                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                    camera = null
                }
                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                    camera = null
                    runOnUiThread { overlay.showError("The camera stopped (error $error).", "Close other camera apps and try again.", canRetry = true) }
                }
            }, handler)
        } catch (exc: SecurityException) {
            overlay.showError("Camera access is off.", "Allow it in Settings to scan.", canRetry = false)
        } catch (exc: Exception) {
            Log.e(TAG, "camera open failed", exc)
            overlay.showError("The camera could not start.", exc.message ?: "", canRetry = true)
        }
    }

    private fun startSession(device: CameraDevice, size: Size) {
        val view = texture ?: return
        val surfaceTexture = view.surfaceTexture ?: return
        val imageReader = reader ?: return
        surfaceTexture.setDefaultBufferSize(size.width, size.height)
        val preview = Surface(surfaceTexture)
        val handler = handler()
        val executor = Executor { handler.post(it) }
        val outputs = listOf(OutputConfiguration(preview), OutputConfiguration(imageReader.surface))
        device.createCaptureSession(SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outputs, executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                        addTarget(preview)
                        addTarget(imageReader.surface)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                    }.build()
                    try {
                        s.setRepeatingRequest(request, null, handler)
                    } catch (exc: Exception) {
                        Log.e(TAG, "preview request failed", exc)
                    }
                }
                override fun onConfigureFailed(s: CameraCaptureSession) {
                    runOnUiThread { overlay.showError("The camera could not start.", "Try again.", canRetry = true) }
                }
            }))
        runOnUiThread { fitPreview(view, size) }
    }

    /** Fill the view with the (portrait-rotated) camera buffer without stretching it. */
    private fun fitPreview(view: TextureView, size: Size) {
        val vw = view.width.toFloat()
        val vh = view.height.toFloat()
        if (vw <= 0f || vh <= 0f) return
        val bw = size.height.toFloat()
        val bh = size.width.toFloat()
        val scale = max(vw / bw, vh / bh)
        view.setTransform(Matrix().apply { setScale(bw * scale / vw, bh * scale / vh, vw / 2f, vh / 2f) })
    }

    /** Camera thread: one frame at a time; the reader drops frames while this decodes. */
    private fun onFrame(r: ImageReader) {
        // A frame can still be queued here after a successful decode closed the reader on the UI thread.
        if (!scanning) return
        val luma: ByteArray
        val w: Int
        val h: Int
        try {
            val image = r.acquireLatestImage() ?: return
            try {
                w = image.width
                h = image.height
                luma = ByteArray(w * h)
                val plane = image.planes[0]
                val buffer = plane.buffer
                for (row in 0 until h) {
                    buffer.position(row * plane.rowStride)
                    buffer.get(luma, row * w, w)
                }
            } finally {
                image.close()
            }
        } catch (_: IllegalStateException) {
            return
        }
        val text = try {
            qr.decode(BinaryBitmap(HybridBinarizer(PlanarYUVLuminanceSource(luma, w, h, 0, 0, w, h, false))), hints).text
        } catch (_: ReaderException) {
            null
        } finally {
            qr.reset()
        }
        if (text == null || !scanning) return
        val isSetup = text.trim().startsWith("ur:", ignoreCase = true)
        val fresh = isSetup && scan.accept(text)
        val result = try {
            scan.result()
        } catch (exc: Exception) {
            Log.w(TAG, "setup decode failed", exc)
            runOnUiThread { overlay.showError("That setup code was damaged.", "Show it again on your computer and rescan.", canRetry = true) }
            return
        }
        val expected = scan.expectedParts
        val got = scan.receivedIndexes.toSet()
        val percent = scan.percent
        runOnUiThread {
            if (!isSetup) overlay.hint("THAT ISN'T A SETUP CODE") else overlay.progress(expected, got, percent, fresh)
            if (result != null) {
                scanning = false
                closeCamera()
                texture?.let(root::removeView)
                texture = null
                showReview(result)
            }
        }
    }

    private fun closeCamera() {
        try {
            session?.close()
        } catch (_: Exception) {
        }
        session = null
        camera?.close()
        camera = null
        reader?.close()
        reader = null
    }

    companion object {
        const val ACTION_IMPORT_CONFIG = "org.permaweb.andee.action.IMPORT_CONFIG"
        const val ACTION_SCAN = "org.permaweb.andee.action.SCAN_SETUP"
        private const val TAG = "SetupImport"
        private const val REQUEST_CAMERA = 7343
    }
}

/** The scan, review and error screens, drawn in the splash's own style (navy ground, mono, cyan, square buttons). */
private class SetupOverlay(context: android.content.Context, private val actions: Actions) : View(context) {
    interface Actions {
        fun use()
        fun back()
        fun retry()
    }

    private enum class Mode { SCANNING, REVIEW, ERROR }

    private var mode = Mode.SCANNING
    private var expected = 0
    private var got: Set<Int> = emptySet()
    private var percent = 0
    private var hintText: String? = null
    private var rows: List<Pair<String, String>> = emptyList()
    private var errorTitle = ""
    private var errorBody = ""
    private var canRetry = false
    private var flashUntil = 0L

    private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = mono; color = INK }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val primary = RectF()
    private val secondary = RectF()
    private var pressed: RectF? = null

    fun showScanning() {
        mode = Mode.SCANNING
        expected = 0; got = emptySet(); percent = 0; hintText = null
        invalidate()
    }

    fun progress(expected: Int, got: Set<Int>, percent: Int, fresh: Boolean) {
        mode = Mode.SCANNING
        this.expected = expected; this.got = got; this.percent = percent; hintText = null
        if (fresh) flashUntil = System.currentTimeMillis() + 180
        invalidate()
    }

    fun hint(message: String) {
        hintText = message
        invalidate()
    }

    fun showReview(rows: List<Pair<String, String>>) {
        mode = Mode.REVIEW
        this.rows = rows
        invalidate()
    }

    fun showError(title: String, body: String, canRetry: Boolean) {
        mode = Mode.ERROR
        errorTitle = title; errorBody = body; this.canRetry = canRetry
        invalidate()
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val m = dp(22f)
        primary.setEmpty(); secondary.setEmpty()
        when (mode) {
            Mode.SCANNING -> drawScanning(canvas, w, h, m)
            Mode.REVIEW -> drawReview(canvas, w, h, m)
            Mode.ERROR -> drawError(canvas, w, h, m)
        }
    }

    private fun title(canvas: Canvas, line: String, sub: String, m: Float, top: Float) {
        text.textSize = dp(17f); text.color = INK
        text.setShadowLayer(dp(9f), 0f, 0f, CYAN)
        canvas.drawText(line, m, top, text)
        text.clearShadowLayer()
        text.textSize = dp(11.5f); text.color = MUTED
        canvas.drawText(sub, m, top + dp(22f), text)
    }

    private fun drawScanning(canvas: Canvas, w: Float, h: Float, m: Float) {
        fill.color = BACKGROUND; fill.alpha = 225
        canvas.drawRect(0f, 0f, w, dp(118f), fill)
        val bottomTop = h - dp(196f)
        canvas.drawRect(0f, bottomTop, w, h, fill)
        fill.alpha = 255
        title(canvas, "SCAN SETUP", "POINT AT YOUR COMPUTER SCREEN", m, dp(64f))

        // the reticle
        val side = min(w - 2 * m, bottomTop - dp(150f))
        val left = (w - side) / 2f
        val top = dp(128f) + (bottomTop - dp(138f) - side) / 2f
        val arm = side * .14f
        stroke.color = if (System.currentTimeMillis() < flashUntil) Color.WHITE else CYAN
        stroke.strokeWidth = dp(3f)
        stroke.setShadowLayer(dp(6f), 0f, 0f, CYAN)
        for ((x, y, dx, dy) in listOf(
            listOf(left, top, 1f, 1f), listOf(left + side, top, -1f, 1f),
            listOf(left, top + side, 1f, -1f), listOf(left + side, top + side, -1f, -1f),
        )) {
            canvas.drawLine(x, y, x + dx * arm, y, stroke)
            canvas.drawLine(x, y, x, y + dy * arm, stroke)
        }
        stroke.clearShadowLayer()

        // ticks for the pure fragments, then the overall meter
        var y = bottomTop + dp(26f)
        text.textSize = dp(11f)
        if (expected == 0) {
            text.color = MUTED
            canvas.drawText(hintText ?: "WAITING FOR THE FIRST CODE…", m, y + dp(12f), text)
        } else {
            val gap = dp(4f)
            val boxW = ((w - 2 * m) - gap * (expected - 1)) / expected
            for (i in 0 until expected) {
                val x = m + i * (boxW + gap)
                if (i in got) {
                    fill.color = CYAN
                    canvas.drawRect(x, y, x + boxW, y + dp(18f), fill)
                } else {
                    stroke.color = Color.argb(115, 238, 251, 255); stroke.strokeWidth = dp(1f)
                    canvas.drawRect(x, y, x + boxW, y + dp(18f), stroke)
                }
            }
        }
        y += dp(30f)
        fill.color = Color.argb(40, 238, 251, 255)
        canvas.drawRect(m, y, w - m, y + dp(6f), fill)
        fill.color = CYAN
        canvas.drawRect(m, y, m + (w - 2 * m) * percent / 100f, y + dp(6f), fill)
        y += dp(24f)
        text.color = INK; text.textSize = dp(11.5f)
        val status = when {
            hintText != null && expected > 0 -> hintText!!
            expected == 0 -> "HOLD ABOUT 30 CM FROM THE SCREEN"
            else -> "$percent% · HOLD STEADY"
        }
        canvas.drawText(status, m, y, text)
        button(canvas, secondary, m, h - dp(72f), w - 2 * m, "CANCEL", filled = true)
    }

    private fun drawReview(canvas: Canvas, w: Float, h: Float, m: Float) {
        canvas.drawColor(BACKGROUND)
        title(canvas, "SETUP RECEIVED", "CHECK IT, THEN USE IT", m, dp(76f))
        var y = dp(140f)
        for ((k, v) in rows) {
            text.textSize = dp(11f); text.color = MUTED
            canvas.drawText(k, m, y, text)
            text.textSize = dp(13.5f); text.color = INK
            for (line in wrap(v, w - 2 * m)) {
                y += dp(19f)
                canvas.drawText(line, m, y, text)
            }
            y += dp(26f)
        }
        text.textSize = dp(11.5f); text.color = MUTED
        for (line in wrap("Your node key is made on this phone. It is never part of the setup.", w - 2 * m)) {
            canvas.drawText(line, m, y, text)
            y += dp(16f)
        }
        button(canvas, primary, m, h - dp(132f), w - 2 * m, "USE THIS SETUP", filled = true, glow = true)
        button(canvas, secondary, m, h - dp(76f), w - 2 * m, "DISCARD", filled = false)
    }

    private fun drawError(canvas: Canvas, w: Float, h: Float, m: Float) {
        canvas.drawColor(BACKGROUND)
        title(canvas, "CAN'T USE THAT", "", m, dp(76f))
        var y = dp(132f)
        text.textSize = dp(15f); text.color = INK
        for (line in wrap(errorTitle, w - 2 * m)) { canvas.drawText(line, m, y, text); y += dp(22f) }
        y += dp(8f)
        text.textSize = dp(12.5f); text.color = MUTED
        for (line in wrap(errorBody, w - 2 * m)) { canvas.drawText(line, m, y, text); y += dp(18f) }
        if (canRetry) button(canvas, primary, m, h - dp(132f), w - 2 * m, "SCAN AGAIN", filled = true)
        button(canvas, secondary, m, h - dp(76f), w - 2 * m, "BACK", filled = !canRetry)
    }

    private fun button(canvas: Canvas, bounds: RectF, x: Float, y: Float, width: Float, label: String, filled: Boolean, glow: Boolean = false) {
        bounds.set(x, y, x + width, y + dp(46f))
        if (filled) {
            fill.color = Color.WHITE
            if (glow) fill.setShadowLayer(dp(12f), 0f, 0f, CYAN)
            canvas.drawRect(bounds, fill)
            fill.clearShadowLayer()
        } else {
            stroke.color = INK; stroke.strokeWidth = dp(1.5f)
            canvas.drawRect(bounds, stroke)
        }
        text.textSize = dp(14f); text.color = if (filled) BACKGROUND else INK
        val fm = text.fontMetrics
        canvas.drawText(label, x + (width - text.measureText(label)) / 2f, y + (dp(46f) - fm.ascent - fm.descent) / 2f, text)
    }

    private fun wrap(value: String, maxWidth: Float): List<String> {
        val lines = mutableListOf<String>()
        var line = ""
        for (word in value.split(' ')) {
            val next = if (line.isEmpty()) word else "$line $word"
            if (text.measureText(next) <= maxWidth || line.isEmpty()) line = next else { lines += line; line = word }
        }
        if (line.isNotEmpty()) lines += line
        return lines
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressed = listOf(primary, secondary).firstOrNull { !it.isEmpty && it.contains(event.x, event.y) }
                return pressed != null
            }
            MotionEvent.ACTION_UP -> {
                if (pressed?.contains(event.x, event.y) == true) performClick()
                pressed = null
                return true
            }
            MotionEvent.ACTION_CANCEL -> { pressed = null; return true }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        when {
            pressed === primary && mode == Mode.REVIEW -> actions.use()
            pressed === primary && mode == Mode.ERROR -> actions.retry()
            pressed === secondary -> actions.back()
        }
        return true
    }

    companion object {
        val BACKGROUND = Color.rgb(3, 14, 46)
        val CYAN = Color.rgb(85, 229, 255)
        val INK = Color.argb(240, 238, 251, 255)
        val MUTED = Color.argb(170, 238, 251, 255)
    }
}
