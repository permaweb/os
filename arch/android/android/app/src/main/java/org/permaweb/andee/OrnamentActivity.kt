package org.permaweb.andee

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.MotionEvent
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Toast
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
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
    private val backgroundPreferences by lazy { getPreferences(MODE_PRIVATE) }

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
                override fun copyNode(url: String) = this@OrnamentActivity.copyNode(url)
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
        if (!backgroundPreferences.getBoolean("background-setup-reviewed", false)) {
            if (backgroundAccessAllowed()) {
                backgroundPreferences.edit().putBoolean("background-setup-reviewed", true).apply()
                maybeRequestNotifications()
            } else {
                showBackgroundAccess()
            }
        }
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
        if (requestCode == REQUEST_BACKGROUND_ACCESS) {
            maybeRequestNotifications()
            return
        }
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

    private fun backgroundAccessAllowed(): Boolean =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    private fun showBackgroundAccess() {
        backgroundPreferences.edit().putBoolean("background-setup-reviewed", true).apply()
        val allowed = backgroundAccessAllowed()
        AlertDialog.Builder(this)
            .setTitle(if (allowed) "Background use allowed" else "Keep your node online")
            .setMessage(
                "Allow background use so your node and its tunnel can stay available when " +
                    "the screen is locked. This uses more battery. Keep your phone plugged in " +
                    "for long sessions.",
            )
            .setPositiveButton(if (allowed) "Android settings" else "Allow background use") { _, _ ->
                requestBackgroundAccess(allowed)
            }
            .setNegativeButton(if (allowed) "Done" else "Not now") { _, _ -> maybeRequestNotifications() }
            .setOnCancelListener { maybeRequestNotifications() }
            .show()
    }

    @SuppressLint("BatteryLife")
    private fun requestBackgroundAccess(alreadyAllowed: Boolean) {
        // Serving the user's HTTP node/tunnel requires an uninterrupted connection;
        // deferred jobs or FCM cannot implement that core function.
        val intent = if (alreadyAllowed) {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        } else {
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        }
        try {
            startActivityForResult(intent, REQUEST_BACKGROUND_ACCESS)
        } catch (_: ActivityNotFoundException) {
            try {
                startActivityForResult(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                    REQUEST_BACKGROUND_ACCESS,
                )
            } catch (_: ActivityNotFoundException) {
                Toast.makeText(this, "Open Android Settings > Battery to allow background use.", Toast.LENGTH_LONG).show()
                maybeRequestNotifications()
            }
        }
    }

    private fun maybeRequestNotifications() {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED ||
            backgroundPreferences.getBoolean("notification-prompted", false)
        ) return
        backgroundPreferences.edit().putBoolean("notification-prompted", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
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

    private fun copyNode(url: String) {
        val origin = NodeDiscovery.origin(url) ?: return
        getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText("Node URL", origin))
        // Android 13+ supplies its own clipboard confirmation.
        if (Build.VERSION.SDK_INT < 33) {
            Toast.makeText(this, "Node URL copied", Toast.LENGTH_SHORT).show()
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
        private const val REQUEST_BACKGROUND_ACCESS = 7344
        private const val REQUEST_NOTIFICATIONS = 7343
    }
}

private class OrnamentView(
    context: android.content.Context,
    private val actions: Actions,
) : FrameLayout(context) {
    interface Actions {
        fun pickNextBootConfig()
        fun terminate()
        fun openNode(url: String)
        fun copyNode(url: String)
        fun configure()
        fun scan()
    }

    private val mono = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    private val splashMark by lazy { BitmapFactory.decodeResource(resources, R.drawable.os_splash_mark) }
    private val splashMarkPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
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
    private val qrLinkBounds = RectF()
    private val urlLinkBounds = RectF()
    private var pressedBounds: RectF? = null
    private var pressedUrl: String? = null
    private val clipBounds = Rect()
    private val clipBoundsF = RectF()
    private val phoneDirty = Rect()

    private var layoutWidth = 0
    private var layoutHeight = 0
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

    // Native controls keep the compact icon buttons reachable by touch, keyboard and TalkBack.
    private val setupButton = Button(context).apply {
        typeface = mono
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        isAllCaps = false
        gravity = Gravity.CENTER
        minHeight = 0
        minimumHeight = 0
        minWidth = 0
        minimumWidth = 0
        setPadding(dp(6f).toInt(), 0, dp(6f).toInt(), 0)
        maxLines = 1
        setHorizontallyScrolling(false)
        setAutoSizeTextTypeUniformWithConfiguration(8, 12, 1, TypedValue.COMPLEX_UNIT_SP)
        compoundDrawablePadding = dp(6f).toInt()
        setOnClickListener {
            if (nextBootConfigPending.get()) actions.terminate() else actions.scan()
        }
    }
    private val settingsButton = iconButton(R.drawable.ic_setup_settings, "Node settings") { actions.configure() }
    private val importButton = iconButton(R.drawable.ic_setup_import, "Import configuration JSON") { actions.pickNextBootConfig() }
    private val copyUrlButton = iconButton(R.drawable.ic_node_copy, "Copy node URL") {
        val status = nodeStatus.get()
        if (status.ready) actions.copyNode(status.url)
    }.apply {
        visibility = View.INVISIBLE
        scaleType = ImageView.ScaleType.FIT_CENTER
        background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), null, ColorDrawable(Color.WHITE))
    }
    private val controls = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        for (button in listOf(settingsButton, importButton)) {
            addView(button, LinearLayout.LayoutParams(dp(48f).toInt(), dp(48f).toInt()).apply {
                if (button === importButton) marginStart = dp(8f).toInt()
            })
        }
    }

    init {
        setWillNotDraw(false)
        addView(setupButton, LayoutParams(dp(132f).toInt(), dp(48f).toInt()))
        addView(controls, LayoutParams(dp(104f).toInt(), dp(48f).toInt()))
        addView(copyUrlButton, LayoutParams(dp(48f).toInt(), dp(48f).toInt()))
        updateControls()
    }

    private fun iconButton(icon: Int, label: String, action: () -> Unit) = ImageButton(context).apply {
        setImageResource(icon)
        imageTintList = ColorStateList.valueOf(Color.WHITE)
        setPadding(dp(13f).toInt(), dp(13f).toInt(), dp(13f).toInt(), dp(13f).toInt())
        background = controlBackground(primary = false)
        contentDescription = label
        tooltipText = label
        setOnClickListener { action() }
    }

    private fun controlBackground(primary: Boolean, pending: Boolean = false): RippleDrawable {
        val shape = GradientDrawable().apply {
            cornerRadius = 0f
            setColor(if (pending) TERMINATE_ORANGE else if (primary) Color.WHITE else BACKGROUND)
            if (!primary) setStroke(dp(1f).toInt().coerceAtLeast(1), Color.argb(110, 255, 255, 255))
        }
        return RippleDrawable(ColorStateList.valueOf(if (primary) 0x22000000 else 0x33FFFFFF), shape, null)
    }

    private fun updateControls() {
        val pending = nextBootConfigPending.get()
        setupButton.text = if (pending) "APPLY & CLOSE" else "CONFIGURE"
        setupButton.contentDescription = if (pending) "Apply configuration and close node" else "Configure by scanning a setup code"
        setupButton.setTextColor(if (pending) Color.WHITE else BACKGROUND)
        setupButton.background = controlBackground(primary = true, pending = pending)
        val icon = if (pending) null else context.getDrawable(R.drawable.ic_setup_scan)?.mutate()?.apply {
            setTint(BACKGROUND)
            setBounds(0, 0, dp(16f).toInt(), dp(16f).toInt())
        }
        setupButton.setCompoundDrawablesRelative(icon, null, null, null)
        importButton.visibility = if (pending) View.GONE else View.VISIBLE
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        updateQrUrl(nodeStatus.get().url)
        ensureLayout()
        val copySize = dp(9f).toInt()
        val copyTarget = dp(48f).toInt()
        val copyLeft = qrLinkBounds.right.toInt() - copySize
        val copyTop = (qrLinkBounds.top - dp(52f)).toInt()
        textPaint.textSize = dp(9f)
        val textCenter = qrLinkBounds.top - dp(12f) + (textPaint.fontMetrics.ascent + textPaint.fontMetrics.descent) / 2f
        val copyPaddingTop = (textCenter - copyTop - copySize / 2f).toInt().coerceIn(0, copyTarget - copySize)
        // The glyph ends at the QR edge; its invisible target extends right, clear of the URL and QR.
        copyUrlButton.setPadding(0, copyPaddingTop, copyTarget - copySize, copyTarget - copyPaddingTop - copySize)
        copyUrlButton.layout(copyLeft, copyTop, copyLeft + copyTarget, copyTop + copyTarget)
        val x = dp(22f).toInt()
        val y = height - dp(142f).toInt()
        setupButton.layout(x, y, x + setupButton.measuredWidth, y + setupButton.measuredHeight)
        val controlsY = y + setupButton.measuredHeight + dp(8f).toInt()
        controls.layout(x, controlsY, x + controls.measuredWidth, controlsY + controls.measuredHeight)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        updateQrUrl(nodeStatus.get().url)
        val qrWidth = qrModulePixels(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec)) * cachedQrRows.size
        setupButton.layoutParams.width = qrWidth
        val labelSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 12f, resources.displayMetrics)
        val labelWidth = setupButton.paint.measureText(setupButton.text.toString()) * labelSize / setupButton.textSize
        val iconWidth = setupButton.compoundDrawablesRelative[0]?.bounds?.width() ?: 0
        val contentWidth = labelWidth + iconWidth + if (iconWidth > 0) setupButton.compoundDrawablePadding else 0
        val padding = ((qrWidth - contentWidth) / 2f).toInt().coerceAtLeast(dp(6f).toInt())
        setupButton.setPadding(padding, 0, padding, 0)
        controls.layoutParams.width = dp(if (importButton.visibility == View.GONE) 48f else 104f).toInt()
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }

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
            updateControls()
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
        if (Rect.intersects(clipBounds, phoneDirty)) drawPhone(canvas)
        if (clipBounds.top < greeterBottom) drawGreeter(canvas)
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
                    copyUrlButton.visibility = if (status.ready) View.VISIBLE else View.INVISIBLE
                    requestLayout()
                    qrBitmapStatus = null
                    changed = true
                }
                if (nextBootConfigPending.get() != pending) {
                    nextBootConfigPending.set(pending)
                    updateControls()
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
        greeterBottom = greeterTopMargin + dp(88f)

        val availableHeight = height - greeterBottom
        val sizeByWidth = width / (PHONE_COLS * 0.42f)
        val sizeByHeight = availableHeight / (PHONE_ROWS * 1.08f) * 1.18f
        phoneTextSize = (min(sizeByWidth, sizeByHeight) * 0.86f)
            .coerceIn(dp(18f), dp(76f)) * 1.332f
        phonePaint.textSize = phoneTextSize
        val charWidth = phonePaint.measureText("M")
        phoneLineHeight = phoneTextSize * 1.08f
        phoneX = width * 0.55f - PHONE_COLS * charWidth / 2f
        phoneTop = 0f
        phoneDirty.set(0, floor(phoneTop).toInt(), width, height)

        val moduleCount = cachedQrRows.size
        val modulePx = qrModulePixels(width, height)
        val qrSize = (modulePx * moduleCount).toFloat()
        val qrX = greeterMargin
        val qrY = height - qrSize - dp(160f)

        qrLinkBounds.set(qrX, qrY, qrX + qrSize, qrY + qrSize)
        qrDrawBounds.set(0f, qrY - dp(56f), width.toFloat(), qrY + qrSize)
    }

    private fun drawGreeter(canvas: Canvas) {
        val size = dp(80f)
        val x = greeterMargin - size * 40f / 1024f
        val y = greeterTopMargin - size * 40f / 1024f
        canvas.drawBitmap(splashMark, null, RectF(x, y, x + size, y + size), splashMarkPaint)

        val labelX = greeterMargin + dp(85.25f)
        val centerY = greeterTopMargin + dp(35.625f)
        textPaint.typeface = mono
        textPaint.color = Color.WHITE
        textPaint.clearShadowLayer()
        textPaint.textSize = dp(12f)
        canvas.drawText("PermawebOS", labelX, centerY - dp(1.5f), textPaint)
        textPaint.textSize = dp(8f)
        canvas.drawText("VERSION ${BuildConfig.VERSION_NAME}", labelX, centerY + dp(10.5f), textPaint)
    }

    private fun drawPhone(canvas: Canvas) {
        if (phoneRows.isEmpty()) updatePhoneFrame(force = true)
        phonePaint.typeface = mono
        phonePaint.textSize = phoneTextSize
        phonePaint.color = Color.WHITE
        phonePaint.setShadowLayer(dp(11f), 0f, 0f, Color.rgb(85, 229, 255))
        val saved = canvas.save()
        canvas.clipRect(0f, phoneTop, width.toFloat(), height.toFloat())
        for ((index, text) in phoneRows.withIndex()) {
            canvas.drawText(text, phoneX, phoneTop + (index + 1) * phoneLineHeight, phonePaint)
        }
        canvas.restoreToCount(saved)
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

    private fun updateQrUrl(url: String) {
        if (cachedQrUrl != url) {
            cachedQrUrl = url
            cachedQrRows = DiscoveryQr.rowsFor(url)
            layoutWidth = 0
            layoutHeight = 0
            ensureLayout()
            qrBitmap?.recycle()
            qrBitmap = null
            qrBitmapStatus = null
        }
    }

    private fun cachedQrBitmap(status: NodeStatus): Bitmap {
        updateQrUrl(status.url)
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
        val modulePx = qrModulePixels(width, height)
        val qrSize = (modulePx * moduleCount).toFloat()
        val qrX = margin
        val qrY = height - qrSize - dp(160f)

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

        val labelWidth = qrSize
        val labelY = qrY - dp(30f)
        accentPaint.typeface = mono
        accentPaint.textSize = dp(10f)
        accentPaint.color = Color.WHITE
        textPaint.typeface = mono
        textPaint.textSize = dp(9f)
        textPaint.color = Color.argb(225, 238, 251, 255)
        textPaint.clearShadowLayer()
        val urlWidth = if (status.ready) labelWidth - dp(15f) else labelWidth
        val url = fitToWidth(if (status.ready) status.url else "Finding your node…", textPaint, urlWidth)
        rectPaint.color = BACKGROUND
        canvas.drawRect(margin - dp(4f), qrY - dp(48f), margin + labelWidth, qrY - dp(4f), rectPaint)
        canvas.drawText(fitToWidth(status.label, accentPaint, labelWidth), margin, labelY, accentPaint)
        textPaint.isUnderlineText = status.ready
        canvas.drawText(url, margin, qrY - dp(12f), textPaint)
        textPaint.isUnderlineText = false
        val linkRight = if (status.ready) margin + labelWidth - dp(9f) else margin + labelWidth
        urlLinkBounds.set(margin - dp(4f), qrY - dp(52f), linkRight, qrY - dp(4f))
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val status = qrBitmapStatus
                pressedBounds = when {
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
        }
        return true
    }

    private fun renderPhoneGrid(elapsed: Float): Array<CharArray> {
        val cols = PHONE_COLS
        val rows = PHONE_ROWS
        val grid = Array(rows) { CharArray(cols) { ' ' } }
        val yaw = elapsed * 0.82f
        val pitch = -0.10f + sin(elapsed * 0.37f) * 0.05f
        val scale = 5.0f
        val cx = cols / 2f
        val cy = rows / 2f - 1.5f

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

    private fun qrModulePixels(w: Int, h: Int): Int {
        val target = min(w * 0.34f, h * 0.16f).coerceAtLeast(dp(132f))
        return max(3, floor(target / cachedQrRows.size).toInt())
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
