package io.ontola.gamenight

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.RoundedCorner
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast
import android.window.OnBackInvokedDispatcher

/// Host mode: the phone runs the Splitscreen Club browser host (the Warp
/// lobby and Luau games, WebGPU + wasm) full screen, to mirror or cast to a
/// TV. A plain Activity rather than a Flutter WebView, so the WebView has
/// real focus: Bluetooth controllers paired with the phone reach the page's
/// Gamepad API only through the focused view.
///
/// It uses Android System WebView, whatever the player's default browser is.
/// When that WebView has no WebGPU, it offers Chrome instead.
class HostActivity : Activity() {
    private lateinit var web: WebView
    private var probed = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL) ?: DEFAULT_URL
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)

        web = WebView(this).apply {
            setBackgroundColor(Color.rgb(0x0d, 0x10, 0x1e))
            isFocusable = true
            isFocusableInTouchMode = true
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            // The lobby plays music and sounds before anyone touches the
            // phone: players use controllers or their own phones.
            settings.mediaPlaybackRequiresUserGesture = false
            addJavascriptInterface(Bridge(), "SplitscreenApp")
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val target = request.url
                    if (target.host == Uri.parse(url).host) return false
                    // Links off the host page (docs, store) open in the browser.
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, target))
                    } catch (e: ActivityNotFoundException) {
                    }
                    return true
                }

                override fun onPageFinished(view: WebView, loaded: String) {
                    if (!probed) {
                        probed = true
                        view.evaluateJavascript(PROBE, null)
                    }
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                    android.util.Log.i("SplitscreenHost", message.message())
                    return true
                }
            }
        }
        // Android 15+ draws apps edge to edge, under the camera cutout and
        // into the rounded corners, which cut off the room's logo and QR.
        // Keep the room inside the safe area, centred, on black.
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            setOnApplyWindowInsetsListener { view, insets ->
                val safe = safeArea(insets)
                view.setPadding(safe[0], safe[1], safe[0], safe[1])
                insets
            }
        }
        setContentView(frame)
        immersive()
        web.loadUrl(url)
        web.requestFocus()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT
            ) { confirmStop() }
        }
    }

    @Deprecated("Android 12 and older")
    override fun onBackPressed() = confirmStop()

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            immersive()
            web.requestFocus()
        }
    }

    override fun onResume() {
        super.onResume()
        web.onResume()
    }

    override fun onPause() {
        web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        web.destroy()
        super.onDestroy()
    }

    private fun confirmStop() {
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Stop hosting?")
            .setMessage("The room closes for everyone.")
            .setPositiveButton("Stop") { _, _ -> finish() }
            .setNegativeButton("Keep hosting", null)
            .setNeutralButton("Cast to TV") { _, _ -> cast() }
            .show()
    }

    /// Android's own screen cast picker. Phones that hide it (Samsung has
    /// Smart View in Quick Settings instead) get a pointer there.
    private fun cast() {
        try {
            startActivity(Intent(Settings.ACTION_CAST_SETTINGS))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, "Swipe down twice and tap Screen cast or Smart View.", Toast.LENGTH_LONG).show()
        }
    }

    /// Horizontal and vertical padding that keeps the page clear of the
    /// camera cutout and the rounded screen corners, the same on both sides.
    private fun safeArea(insets: WindowInsets): IntArray {
        var side = 0
        var edge = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val cut = insets.getInsets(WindowInsets.Type.displayCutout())
            side = maxOf(cut.left, cut.right)
            edge = maxOf(cut.top, cut.bottom)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            insets.displayCutout?.let {
                side = maxOf(it.safeInsetLeft, it.safeInsetRight)
                edge = maxOf(it.safeInsetTop, it.safeInsetBottom)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // A rounded corner of radius r eats about 0.3 r along both edges.
            val radius = listOf(
                RoundedCorner.POSITION_TOP_LEFT, RoundedCorner.POSITION_TOP_RIGHT,
                RoundedCorner.POSITION_BOTTOM_LEFT, RoundedCorner.POSITION_BOTTOM_RIGHT
            ).maxOf { insets.getRoundedCorner(it)?.radius ?: 0 }
            val corner = (radius * 0.3f).toInt()
            side = maxOf(side, corner)
            edge = maxOf(edge, corner)
        }
        return intArrayOf(side, edge)
    }

    private fun immersive() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
        }
    }

    /// The version of Android System WebView (or Chrome, when that provides
    /// the WebView), for the no-WebGPU message.
    private fun webViewVersion(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return ""
        return WebView.getCurrentWebViewPackage()?.versionName ?: ""
    }

    private fun noWebGpu(why: String) {
        android.util.Log.w("SplitscreenHost", "no WebGPU: $why, WebView ${webViewVersion()}")
        if (isFinishing) return
        val chrome = try {
            packageManager.getPackageInfo(CHROME, 0)
            true
        } catch (e: Exception) {
            false
        }
        val version = webViewVersion().substringBefore('.')
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("This phone can't host here yet")
            .setMessage(
                "Hosting needs WebGPU, and this phone's Android System WebView" +
                    (if (version.isNotEmpty()) " ($version)" else "") +
                    " doesn't offer it. Chrome usually does." +
                    (if (chrome) "" else "\n\nInstall Chrome, then try again.")
            )
            .setPositiveButton(if (chrome) "Open in Chrome" else "Get Chrome") { _, _ ->
                openChrome(chrome)
                finish()
            }
            .setNegativeButton("Close") { _, _ -> finish() }
            .setCancelable(false)
            .show()
    }

    private fun openChrome(installed: Boolean) {
        val url = intent.getStringExtra(EXTRA_URL) ?: DEFAULT_URL
        val target = if (installed) {
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).setPackage(CHROME)
        } else {
            Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$CHROME"))
        }
        try {
            startActivity(target)
        } catch (e: ActivityNotFoundException) {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$CHROME")))
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun gpu(ok: Boolean, why: String) {
            if (!ok) runOnUiThread { noWebGpu(why) }
        }
    }

    companion object {
        const val EXTRA_URL = "url"
        const val DEFAULT_URL = "https://splitscreen.club/play/"
        private const val CHROME = "com.android.chrome"

        // Asks for a GPU adapter the way the engine does: navigator.gpu
        // alone can exist on devices whose GPU WebGPU doesn't support.
        private const val PROBE = """
(async () => {
  let ok = false, why = 'no navigator.gpu';
  try {
    if (navigator.gpu) {
      const adapter = await navigator.gpu.requestAdapter();
      ok = !!adapter;
      why = ok ? '' : 'no adapter';
    }
  } catch (e) { why = String(e); }
  SplitscreenApp.gpu(ok, why);
})();
"""
    }
}
