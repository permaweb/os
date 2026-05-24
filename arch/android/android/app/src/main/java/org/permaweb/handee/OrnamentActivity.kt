package org.permaweb.handee

import android.app.Activity
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
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
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
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
        startForegroundService(Intent(this, HandeeService::class.java))
        ornamentView = OrnamentView(
            this,
            object : OrnamentView.Actions {
                override fun pickNextBootConfig() = this@OrnamentActivity.pickNextBootConfig()
                override fun terminate() = this@OrnamentActivity.terminateApp()
            },
        )
        setContentView(ornamentView)
        hideSystemBars()
    }

    override fun onResume() {
        super.onResume()
        startForegroundService(Intent(this, HandeeService::class.java))
        hideSystemBars()
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
            HandeeBootConfigStore.stageNextBootConfig(this, text)
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

    private fun readPickedText(uri: Uri): String {
        return contentResolver.openInputStream(uri)?.use { input ->
            input.bufferedReader(Charsets.UTF_8).readText()
        } ?: throw IllegalArgumentException("selected config was not readable: $uri")
    }

    private fun terminateApp() {
        try {
            HandeeBootConfigStore.commitPendingForNextBoot(this)
            ornamentView.setNextBootConfigPending(false)
        } catch (exc: Exception) {
            Log.e(TAG, "failed to commit pending boot config before terminate", exc)
            return
        }
        startForegroundService(
            Intent(this, HandeeService::class.java)
                .setAction(HandeeService.ACTION_TERMINATE),
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
    }

    private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    private val nodeStatus = AtomicReference(NodeStatus.booting())
    private val nextBootConfigPending = AtomicBoolean(HandeeBootConfigStore.hasPending(context))
    private val pollerRunning = AtomicBoolean(false)
    private var pollerThread: Thread? = null
    private var startedAt = System.nanoTime()
    private var cachedQrUrl = ""
    private var cachedQrRows = QrV2L.rowsFor("http://<node>:8734/")
    private val configButtonBounds = RectF()

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

    fun setNextBootConfigPending(pending: Boolean) {
        nextBootConfigPending.set(pending)
        postInvalidate()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        startedAt = System.nanoTime()
        if (pollerRunning.compareAndSet(false, true)) {
            pollerThread = Thread(::pollNode, "HandEE-Ornament-Probe").also {
                it.isDaemon = true
                it.start()
            }
        }
    }

    override fun onDetachedFromWindow() {
        pollerRunning.set(false)
        pollerThread?.interrupt()
        pollerThread = null
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val status = nodeStatus.get()
        val elapsed = ((System.nanoTime() - startedAt) / 1_000_000_000.0).toFloat()
        drawBackground(canvas)
        val greeterBottom = drawGreeter(canvas)
        drawPhone(canvas, elapsed, greeterBottom)
        drawQr(canvas, status)
        postInvalidateDelayed(33L)
    }

    private fun pollNode() {
        while (pollerRunning.get()) {
            nodeStatus.set(NodeProbe.snapshot())
            nextBootConfigPending.set(HandeeBootConfigStore.hasPending(context))
            postInvalidate()
            try {
                Thread.sleep(2_000L)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun drawBackground(canvas: Canvas) {
        canvas.drawColor(BACKGROUND)
    }

    private fun drawGreeter(canvas: Canvas): Float {
        val margin = dp(22f)
        val topMargin = dp(40f)
        var size = (width / 58f).coerceIn(dp(10f), dp(21f))
        textPaint.typeface = mono
        textPaint.textSize = size
        var maxLine = HYPERBEAM_GREETER.maxOf { textPaint.measureText(it) }
        val available = width - margin * 2f
        if (maxLine > available) {
            size *= available / maxLine
            textPaint.textSize = size
            maxLine = HYPERBEAM_GREETER.maxOf { textPaint.measureText(it) }
        }
        val lineHeight = size * 1.08f
        var y = topMargin + size

        textPaint.color = Color.WHITE
        textPaint.clearShadowLayer()
        for (line in HYPERBEAM_GREETER) {
            canvas.drawText(line, margin, y, textPaint)
            y += lineHeight
        }
        return y + size * 0.55f
    }

    private fun drawPhone(canvas: Canvas, elapsed: Float, greeterBottom: Float) {
        val grid = renderPhoneGrid(elapsed)
        val rows = grid.size
        val cols = grid.first().size
        val availableHeight = height - greeterBottom
        val sizeByWidth = width / (cols * 0.42f)
        val sizeByHeight = availableHeight / (rows * 1.08f) * 1.18f
        val textSize = (min(sizeByWidth, sizeByHeight) * 0.86f).coerceIn(dp(18f), dp(76f))
        phonePaint.typeface = mono
        phonePaint.textSize = textSize
        phonePaint.color = Color.WHITE
        phonePaint.setShadowLayer(dp(11f), 0f, 0f, Color.rgb(85, 229, 255))

        val charWidth = phonePaint.measureText("M")
        val lineHeight = textSize * 1.08f
        val blockWidth = charWidth * cols
        val x = width * 0.62f - blockWidth * 0.50f
        val top = greeterBottom + dp(18f)

        for ((index, row) in grid.withIndex()) {
            val text = String(row)
            canvas.drawText(text, x, top + (index + 1) * lineHeight, phonePaint)
        }
        phonePaint.clearShadowLayer()
    }

    private fun drawQr(canvas: Canvas, status: NodeStatus) {
        val margin = dp(22f)
        if (cachedQrUrl != status.url) {
            cachedQrUrl = status.url
            cachedQrRows = QrV2L.rowsFor(status.url)
        }

        val moduleCount = cachedQrRows.size
        val target = min(width * 0.34f, height * 0.16f).coerceAtLeast(dp(132f))
        val modulePx = max(3, floor(target / moduleCount).toInt())
        val qrSize = (modulePx * moduleCount).toFloat()
        val qrX = margin
        val qrY = height - qrSize - dp(126f)

        rectPaint.style = Paint.Style.FILL
        rectPaint.color = Color.WHITE
        rectPaint.alpha = if (status.ip == null) 188 else 255
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
        val labelText = "NODE URL"

        textPaint.typeface = mono
        textPaint.textSize = (accentPaint.textSize * 0.78f).coerceAtLeast(dp(8f))
        textPaint.color = Color.argb(235, 238, 251, 255)
        textPaint.clearShadowLayer()
        val url = fitMiddle(status.url, max(10, (labelWidth / textPaint.measureText("M")).toInt()))
        val lines = listOf(
            fitToWidth("LIVE AT: $url", textPaint, labelWidth),
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
        for (line in lines) {
            canvas.drawText(line, labelX, textY, textPaint)
            textY += textPaint.textSize * 1.35f
        }
        drawConfigButton(canvas, qrX, qrY + qrSize + dp(18f), qrSize)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val inside = configButtonBounds.contains(event.x, event.y)
        if (event.action == MotionEvent.ACTION_DOWN && inside) return true
        if (event.action == MotionEvent.ACTION_UP && inside) {
            if (nextBootConfigPending.get()) {
                actions.terminate()
            } else {
                actions.pickNextBootConfig()
            }
            return true
        }
        return super.onTouchEvent(event)
    }

    private fun drawConfigButton(canvas: Canvas, x: Float, y: Float, width: Float) {
        val terminate = nextBootConfigPending.get()
        val height = dp(44f)
        configButtonBounds.set(x, y, x + width, y + height)

        rectPaint.style = Paint.Style.FILL
        rectPaint.color = if (terminate) TERMINATE_ORANGE else Color.WHITE
        rectPaint.alpha = 255
        canvas.drawRect(configButtonBounds, rectPaint)

        textPaint.typeface = mono
        textPaint.textSize = (width / 18.2f).coerceIn(dp(10f), dp(16f))
        textPaint.color = if (terminate) Color.WHITE else BACKGROUND
        textPaint.clearShadowLayer()
        val label = if (terminate) "TERMINATE" else "SET NEXT BOOT CONFIG"
        val textWidth = textPaint.measureText(label)
        val metrics = textPaint.fontMetrics
        val textX = x + (width - textWidth) / 2f
        val textY = y + (height - metrics.ascent - metrics.descent) / 2f
        canvas.drawText(label, textX, textY, textPaint)
    }

    private fun renderPhoneGrid(elapsed: Float): Array<CharArray> {
        val cols = 36
        val rows = 29
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
        private val HYPERBEAM_GREETER = listOf(
            "\u2588\u2588\u2557  \u2588\u2588\u2557\u2588\u2588\u2557   \u2588\u2588\u2557\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557\u2588\u2588\u2588\u2588\u2588\u2588\u2557",
            "\u2588\u2588\u2551  \u2588\u2588\u2551\u255a\u2588\u2588\u2557 \u2588\u2588\u2554\u255d\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557\u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557",
            "\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2551 \u255a\u2588\u2588\u2588\u2588\u2554\u255d \u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d",
            "\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2551  \u255a\u2588\u2588\u2554\u255d  \u2588\u2588\u2554\u2550\u2550\u2550\u255d \u2588\u2588\u2554\u2550\u2550\u255d  \u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557",
            "\u2588\u2588\u2551  \u2588\u2588\u2551   \u2588\u2588\u2551   \u2588\u2588\u2551     \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557\u2588\u2588\u2551  \u2588\u2588\u2551",
            "\u255a\u2550\u255d  \u255a\u2550\u255d   \u255a\u2550\u255d   \u255a\u2550\u255d     \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u255d\u255a\u2550\u255d  \u255a\u2550\u255d",
            "\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2557   \u2588\u2588\u2588\u2557",
            "\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557\u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2551",
            "\u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2551\u2588\u2588\u2554\u2588\u2588\u2588\u2588\u2554\u2588\u2588\u2551",
            "\u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557\u2588\u2588\u2554\u2550\u2550\u255d  \u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2551\u2588\u2588\u2551\u255a\u2588\u2588\u2554\u255d\u2588\u2588\u2551 EAT GLASS,",
            "\u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557\u2588\u2588\u2551  \u2588\u2588\u2551\u2588\u2588\u2551 \u255a\u2550\u255d \u2588\u2588\u2551 BUILD THE",
            "\u255a\u2550\u2550\u2550\u2550\u2550\u255d \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u255d\u255a\u2550\u255d  \u255a\u2550\u255d\u255a\u2550\u255d     \u255a\u2550\u255d FUTURE.",
        )
    }
}

private data class Vec3(val x: Float, val y: Float, val z: Float)

private data class NodeStatus(
    val ready: Boolean,
    val ip: String?,
    val url: String,
) {
    companion object {
        fun booting(): NodeStatus = NodeStatus(
            ready = false,
            ip = null,
            url = "http://<node>:8734/",
        )
    }
}

private object NodeProbe {
    fun snapshot(): NodeStatus {
        val ip = lanIpv4()
        val url = when (ip) {
            null -> "http://<node>:8734/"
            else -> "http://$ip:8734/"
        }
        return NodeStatus(
            ready = hyperbeamReady(),
            ip = ip,
            url = url,
        )
    }

    private fun hyperbeamReady(): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", 8734), 450)
                socket.soTimeout = 450
                OutputStreamWriter(socket.getOutputStream(), Charsets.US_ASCII).use { writer ->
                    writer.write(
                        "GET /~meta@1.0/info HTTP/1.0\r\n" +
                            "Host: 127.0.0.1:8734\r\n" +
                            "Connection: close\r\n\r\n",
                    )
                    writer.flush()
                    val firstLine = BufferedReader(
                        InputStreamReader(socket.getInputStream(), Charsets.US_ASCII),
                    ).readLine()
                    firstLine?.startsWith("HTTP/1.") == true && firstLine.contains(" 200")
                }
            }
        } catch (_: Exception) {
            false
        }
    }

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

private object QrV2L {
    fun rowsFor(data: String): Array<BooleanArray> {
        val bytes = data.toByteArray(Charsets.UTF_8)
        val payload = if (bytes.size <= 32) bytes else "http://node-too-long/".toByteArray(Charsets.UTF_8)
        val size = 25
        val modules = Array(size) { BooleanArray(size) }
        val reserved = Array(size) { BooleanArray(size) }

        drawFinder(modules, reserved, 0, 0)
        drawFinder(modules, reserved, 0, size - 7)
        drawFinder(modules, reserved, size - 7, 0)
        drawAlignment(modules, reserved, 18, 18)
        drawTiming(modules, reserved, size)
        put(modules, reserved, 4 * 2 + 9, 8, true, true)
        reserveFormat(reserved, size)

        val dataCodewords = dataCodewords(payload, 34)
        val eccCodewords = rsRemainder(dataCodewords, 10)
        val bits = ArrayList<Int>((dataCodewords.size + eccCodewords.size) * 8)
        for (codeword in dataCodewords + eccCodewords) {
            bits.addAll(bitsInt(codeword, 8))
        }
        placeBits(modules, reserved, bits, size)
        applyFormat(modules, size)
        return addQuietZone(modules, size, 4)
    }

    private fun dataCodewords(data: ByteArray, target: Int): IntArray {
        val bits = ArrayList<Int>(target * 8)
        bits.addAll(listOf(0, 1, 0, 0))
        bits.addAll(bitsInt(data.size, 8))
        for (byte in data) bits.addAll(bitsInt(byte.toInt() and 0xff, 8))
        val maxBits = target * 8
        repeat(max(0, min(4, maxBits - bits.size))) { bits.add(0) }
        while (bits.size % 8 != 0) bits.add(0)

        val codewords = ArrayList<Int>(target)
        var i = 0
        while (i < bits.size && codewords.size < target) {
            var value = 0
            for (j in 0 until 8) value = (value shl 1) or bits[i + j]
            codewords.add(value)
            i += 8
        }
        var pad = 0xec
        while (codewords.size < target) {
            codewords.add(pad)
            pad = if (pad == 0xec) 0x11 else 0xec
        }
        return codewords.toIntArray()
    }

    private fun bitsInt(value: Int, width: Int): List<Int> {
        return (width - 1 downTo 0).map { shift -> (value ushr shift) and 1 }
    }

    private fun rsRemainder(data: IntArray, eccLen: Int): IntArray {
        val generator = rsGenerator(eccLen)
        val remainder = IntArray(eccLen)
        for (byte in data) {
            val factor = byte xor remainder[0]
            for (i in 0 until eccLen - 1) {
                remainder[i] = remainder[i + 1] xor gfMul(factor, generator[i + 1])
            }
            remainder[eccLen - 1] = gfMul(factor, generator[eccLen])
        }
        return remainder
    }

    private fun rsGenerator(degree: Int): IntArray {
        var poly = intArrayOf(1)
        for (i in 0 until degree) {
            poly = polyMul(poly, intArrayOf(1, gfPow2(i)))
        }
        return poly
    }

    private fun polyMul(left: IntArray, right: IntArray): IntArray {
        val out = IntArray(left.size + right.size - 1)
        for (i in left.indices) {
            for (j in right.indices) {
                out[i + j] = out[i + j] xor gfMul(left[i], right[j])
            }
        }
        return out
    }

    private fun gfPow2(power: Int): Int {
        var value = 1
        repeat(power) { value = gfMul(value, 2) }
        return value
    }

    private fun gfMul(a0: Int, b0: Int): Int {
        var a = a0
        var b = b0
        var acc = 0
        while (b != 0) {
            if ((b and 1) != 0) acc = acc xor a
            a = if ((a and 0x80) != 0) ((a shl 1) xor 0x11d) and 0xff else (a shl 1) and 0xff
            b = b ushr 1
        }
        return acc
    }

    private fun drawFinder(
        modules: Array<BooleanArray>,
        reserved: Array<BooleanArray>,
        row0: Int,
        col0: Int,
    ) {
        for (r in -1..7) {
            for (c in -1..7) {
                val separator = r == -1 || r == 7 || c == -1 || c == 7
                val dark = !separator &&
                    (r == 0 || r == 6 || c == 0 || c == 6 || (r in 2..4 && c in 2..4))
                put(modules, reserved, row0 + r, col0 + c, dark, true)
            }
        }
    }

    private fun drawAlignment(
        modules: Array<BooleanArray>,
        reserved: Array<BooleanArray>,
        row0: Int,
        col0: Int,
    ) {
        for (r in -2..2) {
            for (c in -2..2) {
                val dark = abs(r) == 2 || abs(c) == 2 || (r == 0 && c == 0)
                put(modules, reserved, row0 + r, col0 + c, dark, true)
            }
        }
    }

    private fun drawTiming(modules: Array<BooleanArray>, reserved: Array<BooleanArray>, size: Int) {
        for (i in 8 until size - 8) {
            val dark = i % 2 == 0
            put(modules, reserved, 6, i, dark, true)
            put(modules, reserved, i, 6, dark, true)
        }
    }

    private fun reserveFormat(reserved: Array<BooleanArray>, size: Int) {
        for ((row, col) in formatCoords(size)) {
            if (row in 0 until size && col in 0 until size) reserved[row][col] = true
        }
    }

    private fun placeBits(
        modules: Array<BooleanArray>,
        reserved: Array<BooleanArray>,
        bits: List<Int>,
        size: Int,
    ) {
        var bitIndex = 0
        var upward = true
        var col = size - 1
        while (col > 0) {
            if (col == 6) col--
            val rowRange = if (upward) size - 1 downTo 0 else 0 until size
            for (row in rowRange) {
                for (c in col downTo col - 1) {
                    if (!reserved[row][c]) {
                        val bit = bits.getOrElse(bitIndex) { 0 }
                        bitIndex++
                        val mask = (row + c) % 2 == 0
                        modules[row][c] = (bit == 1) xor mask
                    }
                }
            }
            upward = !upward
            col -= 2
        }
    }

    private fun applyFormat(modules: Array<BooleanArray>, size: Int) {
        val bits = IntArray(15) { i -> (0x77c4 ushr i) and 1 }
        val coords = formatCoords(size)
        for (i in coords.indices) {
            val (row, col) = coords[i]
            modules[row][col] = bits[i % 15] == 1
        }
    }

    private fun addQuietZone(modules: Array<BooleanArray>, size: Int, quiet: Int): Array<BooleanArray> {
        val total = size + quiet * 2
        val out = Array(total) { BooleanArray(total) }
        for (r in 0 until total) {
            for (c in 0 until total) {
                val innerR = r - quiet
                val innerC = c - quiet
                if (innerR in 0 until size && innerC in 0 until size) {
                    out[r][c] = modules[innerR][innerC]
                }
            }
        }
        return out
    }

    private fun put(
        modules: Array<BooleanArray>,
        reserved: Array<BooleanArray>,
        row: Int,
        col: Int,
        dark: Boolean,
        reserve: Boolean,
    ) {
        if (row in modules.indices && col in modules[row].indices) {
            modules[row][col] = dark
            if (reserve) reserved[row][col] = true
        }
    }

    private fun formatCoords(size: Int): List<Pair<Int, Int>> {
        return listOf(
            0 to 8,
            1 to 8,
            2 to 8,
            3 to 8,
            4 to 8,
            5 to 8,
            7 to 8,
            8 to 8,
            8 to 7,
            8 to 5,
            8 to 4,
            8 to 3,
            8 to 2,
            8 to 1,
            8 to 0,
            8 to size - 1,
            8 to size - 2,
            8 to size - 3,
            8 to size - 4,
            8 to size - 5,
            8 to size - 6,
            8 to size - 7,
            8 to size - 8,
            size - 7 to 8,
            size - 6 to 8,
            size - 5 to 8,
            size - 4 to 8,
            size - 3 to 8,
            size - 2 to 8,
            size - 1 to 8,
        )
    }
}
