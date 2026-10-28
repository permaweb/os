package org.permaweb.andee

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Toast
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

class OrnamentActivity : Activity() {
    private lateinit var ornamentView: OrnamentView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        if (Build.VERSION.SDK_INT >= 28) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        startForegroundService(Intent(this, AndeeService::class.java))
        ornamentView = OrnamentView(
            this,
            object : OrnamentView.Actions {
                override fun pickNextBootConfig() = this@OrnamentActivity.pickNextBootConfig()
                override fun terminate() = this@OrnamentActivity.terminateApp()
                override fun openNode(url: String) = this@OrnamentActivity.openNode(url)
                override fun configure() {
                    startActivity(Intent(this@OrnamentActivity, ConfiguratorActivity::class.java))
                }
                override fun scan() {
                    startActivity(
                        Intent(this@OrnamentActivity, SetupImportActivity::class.java)
                            .setAction(SetupImportActivity.ACTION_SCAN),
                    )
                }
            },
        )
        setContentView(ornamentView)
        hideSystemBars()
    }

    override fun onResume() {
        super.onResume()
        startForegroundService(Intent(this, AndeeService::class.java))
        ornamentView.resumePresentation()
        hideSystemBars()
    }

    override fun onPause() {
        ornamentView.pausePresentation()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            window.insetsController?.hide(WindowInsets.Type.systemBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    @Deprecated("Deprecated by Activity; used here to avoid adding an AndroidX dependency.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_BOOT_CONFIG || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        try {
            val text = readPickedText(uri)
            AndeeBootConfigStore.stageNextBootConfig(this, text)
            ornamentView.setNextBootConfigPending(true)
            hideSystemBars()
        } catch (exc: Exception) {
            Log.e(TAG, "failed to import next boot config", exc)
        }
    }

    private fun pickNextBootConfig() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/json", "text/plain"),
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
        }
        startActivityForResult(intent, REQUEST_BOOT_CONFIG)
    }

    private fun openNode(url: String) {
        val origin = NodeDiscovery.origin(url) ?: return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(origin)).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
            })
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "Install a browser to open your node.", Toast.LENGTH_LONG).show()
        }
    }

    private fun readPickedText(uri: Uri): String {
        return contentResolver.openInputStream(uri)?.use { input ->
            input.bufferedReader(Charsets.UTF_8).readText()
        } ?: throw IllegalArgumentException("selected config was not readable: $uri")
    }

    private fun terminateApp() {
        try {
            AndeeBootConfigStore.commitPendingForNextBoot(this)
            ornamentView.setNextBootConfigPending(false)
        } catch (exc: Exception) {
            Log.e(TAG, "failed to commit pending boot config before terminate", exc)
            return
        }
        startForegroundService(
            Intent(this, AndeeService::class.java)
                .setAction(AndeeService.ACTION_TERMINATE),
        )
        finishAndRemoveTask()
    }

    companion object {
        private const val TAG = "OrnamentActivity"
        private const val REQUEST_BOOT_CONFIG = 7342
    }
}

private class OrnamentView(
    context: android.content.Context,
    private val actions: Actions,
) : View(context) {
    interface Actions {
        fun pickNextBootConfig()
        fun terminate()
        fun openNode(url: String)
        fun configure()
        fun scan()
    }

    private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    private val brandMark = BitmapFactory.decodeResource(resources, R.drawable.permawebos_mark)
    private val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val brandBounds = RectF()
    private val nodeStatus = AtomicReference(NodeStatus.booting())
    private val nextBootConfigPending = AtomicBoolean(AndeeBootConfigStore.hasPending(context))
    private val presentationActive = AtomicBoolean(false)
    private val pollerRunning = AtomicBoolean(false)
    private var pollerThread: Thread? = null
    private var animationFramePending = false
    private var startedAt = System.nanoTime()
    private var cachedQrUrl = ""
    private var cachedQrRows = DiscoveryQr.rowsFor("http://<node>:8734/")
    private var phoneRows: List<String> = emptyList()
    private var qrBitmap: Bitmap? = null
    private var qrBitmapStatus: NodeStatus? = null
    private var qrBitmapPending = false
    private val configButtonBounds = RectF()
    private val configureButtonBounds = RectF()
    private val scanButtonBounds = RectF()
    private val qrLinkBounds = RectF()
    private val urlLinkBounds = RectF()
    private var pressedBounds: RectF? = null
    private var pressedUrl: String? = null
    private val clipBounds = Rect()
    private val clipBoundsF = RectF()
    private val phoneDirty = Rect()

    private var layoutWidth = 0
    private var layoutHeight = 0
    private var greeterTextSize = 0f
    private var greeterMargin = 0f
    private var greeterTopMargin = 0f
    private var greeterBottom = 0f
    private var phoneTextSize = 0f
    private var phoneLineHeight = 0f
    private var phoneX = 0f
    private var phoneTop = 0f
    private val qrDrawBounds = RectF()

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        typeface = mono
        isSubpixelText = true
    }
    private val phonePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        typeface = mono
        isSubpixelText = true
    }
    private val accentPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(91, 238, 255)
        typeface = mono
        isSubpixelText = true
    }
    private val rectPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private val animationTick = object : Runnable {
        override fun run() {
            animationFramePending = false
            if (!presentationActive.get()) return
            if (updatePhoneFrame(force = false)) invalidatePhone()
            scheduleAnimationFrame()
        }
    }

    fun setNextBootConfigPending(pending: Boolean) {
        if (nextBootConfigPending.getAndSet(pending) != pending) {
            qrBitmapStatus = null
            invalidate()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        resumePresentation()
    }

    override fun onDetachedFromWindow() {
        pausePresentation()
        super.onDetachedFromWindow()
    }

    fun resumePresentation() {
        startedAt = System.nanoTime()
        updatePhoneFrame(force = true)
        if (presentationActive.compareAndSet(false, true)) startPoller()
        invalidate()
        scheduleAnimationFrame()
    }

    fun pausePresentation() {
        presentationActive.set(false)
        removeCallbacks(animationTick)
        animationFramePending = false
        stopPoller()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        layoutWidth = 0
        layoutHeight = 0
        qrBitmap?.recycle()
        qrBitmap = null
    }

    private fun startPoller() {
        if (!pollerRunning.compareAndSet(false, true)) return
        pollerThread = Thread(::pollNode, "AndEE-Ornament-Probe").also {
            it.isDaemon = true
            it.start()
        }
    }

    private fun stopPoller() {
        pollerRunning.set(false)
        pollerThread?.interrupt()
        pollerThread = null
    }

    override fun onDraw(canvas: Canvas) {
        if (width <= 0 || height <= 0) return
        ensureLayout()
        if (!canvas.getClipBounds(clipBounds)) {
            clipBounds.set(0, 0, width, height)
        }
        clipBoundsF.set(clipBounds)

        val status = nodeStatus.get()
        drawBackground(canvas)
        if (clipBounds.top < greeterBottom) drawGreeter(canvas)
        if (Rect.intersects(clipBounds, phoneDirty)) drawPhone(canvas)
        if (RectF.intersects(qrDrawBounds, clipBoundsF)) drawQr(canvas, status)
    }

    private fun pollNode() {
        while (presentationActive.get() && pollerRunning.get()) {
            val status = NodeProbe.snapshot()
            val pending = AndeeBootConfigStore.hasPending(context)
            post {
                var changed = false
                if (nodeStatus.get() != status) {
                    nodeStatus.set(status)
                    qrBitmapStatus = null
                    changed = true
                }
                if (nextBootConfigPending.get() != pending) {
                    nextBootConfigPending.set(pending)
                    qrBitmapStatus = null
                    changed = true
                }
                if (changed) invalidate()
            }
            try {
                Thread.sleep(if (status.ready && status.ip != null) STEADY_POLL_MS else BOOT_POLL_MS)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun scheduleAnimationFrame() {
        if (animationFramePending || !presentationActive.get() || !isAttachedToWindow) return
        animationFramePending = true
        postDelayed(animationTick, ANIMATION_FRAME_MS)
    }

    private fun invalidatePhone() {
        if (width <= 0 || height <= 0) {
            invalidate()
            return
        }
        ensureLayout()
        postInvalidateOnAnimation(
            phoneDirty.left,
            phoneDirty.top,
            phoneDirty.right,
            phoneDirty.bottom,
        )
    }

    private fun drawBackground(canvas: Canvas) {
        canvas.drawColor(BACKGROUND)
    }

    private fun ensureLayout() {
        if (layoutWidth == width && layoutHeight == height) return
        layoutWidth = width
        layoutHeight = height
        greeterMargin = dp(22f)
        greeterTopMargin = dp(40f)
        val markSize = min(dp(132f), width * 0.34f)
        brandBounds.set(greeterMargin, greeterTopMargin, greeterMargin + markSize, greeterTopMargin + markSize)
        var size = dp(24f)
        textPaint.typeface = mono
        textPaint.textSize = size
        val maxLine = textPaint.measureText("PERMAWEBOS")
        val available = width - brandBounds.right - dp(12f) - greeterMargin
        if (maxLine > available) {
            size *= available / maxLine
            textPaint.textSize = size
        }
        greeterTextSize = size
        greeterBottom = brandBounds.bottom + dp(20f)

        val rows = PHONE_ROWS
        val cols = PHONE_COLS
        val availableHeight = height - greeterBottom
        val sizeByWidth = width / (cols * 0.42f)
        val sizeByHeight = availableHeight / (rows * 1.08f) * 1.18f
        phoneTextSize = (min(sizeByWidth, sizeByHeight) * 0.86f).coerceIn(dp(18f), dp(76f))
        phonePaint.typeface = mono
        phonePaint.textSize = phoneTextSize
        val charWidth = phonePaint.measureText("M")
        phoneLineHeight = phoneTextSize * 1.08f
        val blockWidth = charWidth * cols
        phoneX = width * 0.62f - blockWidth * 0.50f
        phoneTop = greeterBottom + dp(18f)
        val phonePad = dp(18f)
        phoneDirty.set(
            floor(phoneX - phonePad).toInt().coerceAtLeast(0),
            floor(phoneTop - phonePad).toInt().coerceAtLeast(0),
            kotlin.math.ceil(phoneX + blockWidth + phonePad).toInt().coerceAtMost(width),
            kotlin.math.ceil(phoneTop + rows * phoneLineHeight + phonePad).toInt().coerceAtMost(height),
        )

        val moduleCount = cachedQrRows.size
        val target = min(width * 0.34f, height * 0.16f).coerceAtLeast(dp(132f))
        val modulePx = max(3, floor(target / moduleCount).toInt())
        val qrSize = (modulePx * moduleCount).toFloat()
        val qrX = greeterMargin
        val qrY = height - qrSize - dp(126f)

        qrLinkBounds.set(qrX, qrY, qrX + qrSize, qrY + qrSize)
        qrDrawBounds.set(0f, qrY - dp(28f), width.toFloat(), qrY + qrSize + dp(74f))
    }

    private fun drawGreeter(canvas: Canvas) {
        canvas.drawBitmap(brandMark, null, brandBounds, brandPaint)
        val x = brandBounds.right + dp(12f)
        val y = brandBounds.centerY()
        textPaint.color = Color.WHITE
        textPaint.clearShadowLayer()
        textPaint.typeface = mono
        textPaint.textSize = greeterTextSize
        canvas.drawText("PERMAWEBOS", x, y, textPaint)
        textPaint.textSize = dp(16f)
        canvas.drawText("Your node", x, y + dp(26f), textPaint)
    }

    private fun drawPhone(canvas: Canvas) {
        if (phoneRows.isEmpty()) updatePhoneFrame(force = true)
        phonePaint.typeface = mono
        phonePaint.textSize = phoneTextSize
        phonePaint.color = Color.WHITE
        phonePaint.setShadowLayer(dp(11f), 0f, 0f, Color.rgb(85, 229, 255))

        for ((index, text) in phoneRows.withIndex()) {
            canvas.drawText(text, phoneX, phoneTop + (index + 1) * phoneLineHeight, phonePaint)
        }
        phonePaint.clearShadowLayer()
    }

    private fun updatePhoneFrame(force: Boolean): Boolean {
        val elapsed = ((System.nanoTime() - startedAt) / 1_000_000_000.0).toFloat()
        val nextRows = renderPhoneRows(elapsed)
        if (!force && nextRows == phoneRows) return false
        phoneRows = nextRows
        return true
    }

    private fun renderPhoneRows(elapsed: Float): List<String> =
        renderPhoneGrid(elapsed).map { String(it) }

    private fun drawQr(canvas: Canvas, status: NodeStatus) {
        val bitmap = cachedQrBitmap(status)
        canvas.drawBitmap(bitmap, qrDrawBounds.left, qrDrawBounds.top, null)
    }

    private fun cachedQrBitmap(status: NodeStatus): Bitmap {
        if (cachedQrUrl != status.url) {
            cachedQrUrl = status.url
            cachedQrRows = DiscoveryQr.rowsFor(status.url)
            layoutWidth = 0
            layoutHeight = 0
            ensureLayout()
            qrBitmap?.recycle()
            qrBitmap = null
            qrBitmapStatus = null
        }

        val left = floor(qrDrawBounds.left).toInt()
        val top = floor(qrDrawBounds.top).toInt()
        val bitmapWidth = kotlin.math.ceil(qrDrawBounds.width()).toInt().coerceAtLeast(1)
        val bitmapHeight = kotlin.math.ceil(qrDrawBounds.height()).toInt().coerceAtLeast(1)
        val pending = nextBootConfigPending.get()
        val current = qrBitmap
        if (
            current != null &&
            !current.isRecycled &&
            current.width == bitmapWidth &&
            current.height == bitmapHeight &&
            qrBitmapStatus == status &&
            qrBitmapPending == pending
        ) {
            return current
        }

        current?.recycle()
        val next = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
        next.eraseColor(Color.TRANSPARENT)
        Canvas(next).also { bitmapCanvas ->
            bitmapCanvas.translate(-left.toFloat(), -top.toFloat())
            drawQrDirect(bitmapCanvas, status)
        }
        qrBitmap = next
        qrBitmapStatus = status
        qrBitmapPending = pending
        return next
    }

    private fun drawQrDirect(canvas: Canvas, status: NodeStatus) {
        val margin = dp(22f)

        val moduleCount = cachedQrRows.size
        val target = min(width * 0.34f, height * 0.16f).coerceAtLeast(dp(132f))
        val modulePx = max(3, floor(target / moduleCount).toInt())
        val qrSize = (modulePx * moduleCount).toFloat()
        val qrX = margin
        val qrY = height - qrSize - dp(126f)

        rectPaint.style = Paint.Style.FILL
        rectPaint.color = Color.WHITE
        rectPaint.alpha = if (status.ready) 255 else 188
        canvas.drawRect(qrX, qrY, qrX + qrSize, qrY + qrSize, rectPaint)

        rectPaint.alpha = 255
        rectPaint.color = Color.rgb(1, 10, 29)
        for (r in 0 until moduleCount) {
            for (c in 0 until moduleCount) {
                if (cachedQrRows[r][c]) {
                    val left = qrX + c * modulePx
                    val top = qrY + r * modulePx
                    canvas.drawRect(left, top, left + modulePx, top + modulePx, rectPaint)
                }
            }
        }

        val labelX = qrX + qrSize + dp(18f)
        val labelWidth = width - labelX - margin
        accentPaint.typeface = mono
        accentPaint.textSize = (width / 42f).coerceIn(dp(10f), dp(18f))
        accentPaint.color = Color.WHITE
        val labelY = qrY + accentPaint.textSize
        val labelText = status.label

        textPaint.typeface = mono
        textPaint.textSize = (accentPaint.textSize * 0.78f).coerceAtLeast(dp(8f))
        textPaint.color = Color.argb(235, 238, 251, 255)
        textPaint.clearShadowLayer()
        val url = fitMiddle(status.url, max(10, (labelWidth / textPaint.measureText("M")).toInt()))
        val lines = listOf(
            fitToWidth(if (status.ready) url else "Waiting for node discovery", textPaint, labelWidth),
        )
        val backingWidth = (
            listOf(accentPaint.measureText(labelText)) +
                lines.map { textPaint.measureText(it) }
        ).maxOrNull()?.coerceAtMost(labelWidth) ?: 0f

        rectPaint.style = Paint.Style.FILL
        rectPaint.color = BACKGROUND
        canvas.drawRect(
            labelX - dp(4f),
            labelY - accentPaint.textSize * 1.25f,
            labelX + backingWidth + dp(6f),
            labelY + accentPaint.textSize * 2.25f,
            rectPaint,
        )
        canvas.drawText(labelText, labelX, labelY, accentPaint)

        var textY = labelY + accentPaint.textSize * 1.4f
        textPaint.isUnderlineText = status.ready
        for (line in lines) {
            canvas.drawText(line, labelX, textY, textPaint)
            textY += textPaint.textSize * 1.35f
        }
        textPaint.isUnderlineText = false
        urlLinkBounds.set(labelX - dp(4f), qrY, width - margin, max(qrY + dp(48f), textY))
        val buttonY = qrY + qrSize + dp(18f)
        drawActionButton(canvas, configureButtonBounds, qrX, buttonY, qrSize, "CONFIGURE")
        val pending = nextBootConfigPending.get()
        if (pending) {
            scanButtonBounds.setEmpty()
            drawActionButton(canvas, configButtonBounds, labelX, buttonY, labelWidth, "APPLY & CLOSE", true)
        } else {
            // SCAN reads the setup code the PermawebOS extension shows; LOAD JSON picks a file
            val half = (labelWidth - dp(8f)) / 2f
            drawActionButton(canvas, scanButtonBounds, labelX, buttonY, half, "SCAN")
            drawActionButton(canvas, configButtonBounds, labelX + half + dp(8f), buttonY, half, "LOAD JSON")
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val status = qrBitmapStatus
                pressedBounds = when {
                    configButtonBounds.contains(event.x, event.y) -> configButtonBounds
                    configureButtonBounds.contains(event.x, event.y) -> configureButtonBounds
                    !scanButtonBounds.isEmpty && scanButtonBounds.contains(event.x, event.y) -> scanButtonBounds
                    status?.ready == true && qrLinkBounds.contains(event.x, event.y) -> qrLinkBounds
                    status?.ready == true && urlLinkBounds.contains(event.x, event.y) -> urlLinkBounds
                    else -> null
                }
                pressedUrl = if (pressedBounds === qrLinkBounds || pressedBounds === urlLinkBounds) status?.url else null
                if (pressedBounds != null) return true
            }
            MotionEvent.ACTION_MOVE -> {
                val bounds = pressedBounds
                if (bounds != null && !bounds.contains(event.x, event.y)) {
                    pressedBounds = null
                    pressedUrl = null
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (pressedBounds?.contains(event.x, event.y) == true) performClick()
                pressedBounds = null
                pressedUrl = null
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                pressedBounds = null
                pressedUrl = null
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        val url = pressedUrl
        if (url != null) {
            val current = nodeStatus.get()
            if (current.ready && current.url == url) actions.openNode(url)
        } else if (pressedBounds === configButtonBounds) {
            if (nextBootConfigPending.get()) actions.terminate() else actions.pickNextBootConfig()
        } else if (pressedBounds === configureButtonBounds) {
            actions.configure()
        } else if (pressedBounds === scanButtonBounds) {
            actions.scan()
        }
        return true
    }

    private fun drawActionButton(canvas: Canvas, bounds: RectF, x: Float, y: Float, width: Float,
        label: String, terminate: Boolean = false) {
        val height = dp(44f)
        bounds.set(x, y, x + width, y + height)

        rectPaint.style = Paint.Style.FILL
        rectPaint.color = if (terminate) TERMINATE_ORANGE else Color.WHITE
        rectPaint.alpha = 255
        canvas.drawRect(bounds, rectPaint)

        textPaint.typeface = mono
        textPaint.textSize = (width / 12f).coerceIn(dp(10f), dp(16f))
        textPaint.color = if (terminate) Color.WHITE else BACKGROUND
        textPaint.clearShadowLayer()
        val textWidth = textPaint.measureText(label)
        val metrics = textPaint.fontMetrics
        val textX = x + (width - textWidth) / 2f
        val textY = y + (height - metrics.ascent - metrics.descent) / 2f
        canvas.drawText(label, textX, textY, textPaint)
    }

    private fun renderPhoneGrid(elapsed: Float): Array<CharArray> {
        val cols = PHONE_COLS
        val rows = PHONE_ROWS
        val grid = Array(rows) { CharArray(cols) { ' ' } }
        val yaw = elapsed * 0.82f
        val pitch = -0.10f + sin(elapsed * 0.37f) * 0.05f
        val scale = 8.15f
        val cx = cols / 2f
        val cy = rows / 2f + 1.35f

        for ((from, to) in phoneEdges()) {
            val p1 = project(from, yaw, pitch, scale, cx, cy)
            val p2 = project(to, yaw, pitch, scale, cx, cy)
            drawAsciiLine(grid, p1.first, p1.second, p2.first, p2.second)
        }

        return grid
    }

    private fun project(
        point: Vec3,
        yaw: Float,
        pitch: Float,
        scale: Float,
        cx: Float,
        cy: Float,
    ): Pair<Int, Int> {
        val cyaw = cos(yaw)
        val syaw = sin(yaw)
        val x1 = point.x * cyaw + point.z * syaw
        val z1 = -point.x * syaw + point.z * cyaw

        val cp = cos(pitch)
        val sp = sin(pitch)
        val y2 = point.y * cp - z1 * sp
        val z2 = point.y * sp + z1 * cp

        val tilt = 0.48f
        val yView = y2 * cos(tilt) - z2 * sin(tilt)
        val perspective = 1.0f / (1.0f + (z2 + 3.8f) * 0.035f)
        val col = (cx + x1 * scale * perspective).roundToInt()
        val row = (cy - yView * scale * 0.58f * perspective).roundToInt()
        return col to row
    }

    private fun drawAsciiLine(grid: Array<CharArray>, x0: Int, y0: Int, x1: Int, y1: Int) {
        val dxAbs = abs(x1 - x0)
        val dyAbs = abs(y1 - y0)
        val ch = when {
            dyAbs * 2 < dxAbs -> '-'
            dxAbs * 2 < dyAbs -> '|'
            (x1 - x0) * (y1 - y0) > 0 -> '\\'
            else -> '/'
        }

        var x = x0
        var y = y0
        val sx = if (x0 < x1) 1 else -1
        val sy = if (y0 < y1) 1 else -1
        var err = dxAbs - dyAbs
        while (true) {
            plot(grid, x, y, ch)
            if (x == x1 && y == y1) break
            val e2 = err * 2
            if (e2 > -dyAbs) {
                err -= dyAbs
                x += sx
            }
            if (e2 < dxAbs) {
                err += dxAbs
                y += sy
            }
        }
        plot(grid, x0, y0, '+')
        plot(grid, x1, y1, '+')
    }

    private fun plot(grid: Array<CharArray>, x: Int, y: Int, ch: Char) {
        if (y in grid.indices && x in grid[y].indices) {
            grid[y][x] = ch
        }
    }

    private fun phoneEdges(): List<Pair<Vec3, Vec3>> {
        val xl = -1.62f
        val xr = 1.62f
        val yt = 3.75f
        val yb = -3.75f
        val zf = 0.22f
        val zb = -0.22f
        val front = listOf(
            Vec3(xl, yt, zf),
            Vec3(xr, yt, zf),
            Vec3(xr, yb, zf),
            Vec3(xl, yb, zf),
        )
        val back = listOf(
            Vec3(xl, yt, zb),
            Vec3(xr, yt, zb),
            Vec3(xr, yb, zb),
            Vec3(xl, yb, zb),
        )
        val screen = listOf(
            Vec3(-1.16f, 2.82f, zf + 0.03f),
            Vec3(1.16f, 2.82f, zf + 0.03f),
            Vec3(1.16f, -2.52f, zf + 0.03f),
            Vec3(-1.16f, -2.52f, zf + 0.03f),
        )
        return buildList {
            addLoop(front)
            addLoop(back)
            for (i in front.indices) add(front[i] to back[i])
            addLoop(screen)
            add(Vec3(-0.36f, 3.18f, zf + 0.04f) to Vec3(0.36f, 3.18f, zf + 0.04f))
            add(Vec3(-0.24f, -3.10f, zf + 0.04f) to Vec3(0.24f, -3.10f, zf + 0.04f))
            add(Vec3(0.52f, 3.20f, zf + 0.04f) to Vec3(0.58f, 3.20f, zf + 0.04f))
        }
    }

    private fun MutableList<Pair<Vec3, Vec3>>.addLoop(points: List<Vec3>) {
        for (i in points.indices) add(points[i] to points[(i + 1) % points.size])
    }

    private fun fitToWidth(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        val charWidth = paint.measureText("M").coerceAtLeast(1f)
        return fitMiddle(text, max(4, (maxWidth / charWidth).toInt()))
    }

    private fun fitMiddle(text: String, maxChars: Int): String {
        if (text.length <= maxChars) return text
        if (maxChars <= 3) return text.take(maxChars)
        val left = max(1, (maxChars - 1) / 2)
        val right = max(1, maxChars - left - 1)
        return text.take(left) + "~" + text.takeLast(right)
    }

    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    companion object {
        private val BACKGROUND = Color.rgb(3, 14, 46)
        private val TERMINATE_ORANGE = Color.rgb(164, 76, 0)
        private const val ANIMATION_FRAME_MS = 100L
        private const val BOOT_POLL_MS = 1_000L
        private const val STEADY_POLL_MS = 5_000L
        private const val PHONE_COLS = 36
        private const val PHONE_ROWS = 29
    }
}

private data class Vec3(val x: Float, val y: Float, val z: Float)

private object NodeProbe {
    fun snapshot(): NodeStatus = NodeDiscovery.snapshot(lanIpv4(), NodeMetadataHttp::read)

    private fun lanIpv4(): String? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                if (!networkInterface.isUp || networkInterface.isLoopback || networkInterface.isVirtual) {
                    continue
                }
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (
                        address is Inet4Address &&
                        !address.isLoopbackAddress &&
                        !address.isLinkLocalAddress
                    ) {
                        return address.hostAddress
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }
}
