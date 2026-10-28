package org.permaweb.andee

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast

/** The existing web configurator stages through the same measured path as JSON import. */
class ConfiguratorActivity : Activity() {
    private lateinit var web: WebView
    private val location = ConfiguratorLocation(BuildConfig.CONFIGURATOR_URL)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        web = WebView(this).apply {
            setOnApplyWindowInsetsListener { view, insets ->
                if (Build.VERSION.SDK_INT >= 30) {
                    val bars = insets.getInsets(WindowInsets.Type.systemBars())
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                } else {
                    @Suppress("DEPRECATION")
                    view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                        insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                }
                insets
            }
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (location.contains(request.url.toString())) return false
                    if (request.isForMainFrame && request.url.scheme == "https") {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, request.url))
                        } catch (_: ActivityNotFoundException) {
                            Toast.makeText(this@ConfiguratorActivity, "Install a browser to open this link.", Toast.LENGTH_LONG).show()
                        }
                    }
                    return true
                }
            }
            addJavascriptInterface(Bridge(), "AndeeBridge")
        }
        setContentView(web)
        web.loadUrl(location.url)
    }

    override fun onDestroy() {
        web.removeJavascriptInterface("AndeeBridge")
        web.destroy()
        super.onDestroy()
    }

    private inner class Bridge {
        @JavascriptInterface
        fun isAndee(): Boolean = true

        @JavascriptInterface
        fun stageNextBootConfig(json: String): String = try {
            AndeeBootConfigStore.stageNextBootConfig(this@ConfiguratorActivity, json)
            runOnUiThread { finish() }
            "staged"
        } catch (_: Exception) {
            "error: The configuration could not be saved. Check its fields and try again."
        }
    }
}
