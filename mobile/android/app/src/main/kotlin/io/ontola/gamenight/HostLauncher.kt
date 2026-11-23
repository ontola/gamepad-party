package io.ontola.gamenight

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.browser.trusted.ScreenOrientation
import androidx.browser.trusted.TrustedWebActivityDisplayMode
import androidx.browser.trusted.TrustedWebActivityIntentBuilder
import com.google.androidbrowserhelper.trusted.TwaLauncher

/// Host mode: opens the browser host full screen. With Chrome on the phone
/// it runs in Chrome as a Trusted Web Activity (splitscreen.club's
/// assetlinks.json vouches for this app, so there is no address bar):
/// Chrome's own WebGPU and gamepads, and the engine's long loading frames
/// stall Chrome, not this app. The in-app WebView (HostActivity) blocked
/// this app's input while the page was busy, so Android kept saying
/// "Splitscreen Club isn't responding". Without Chrome it falls back to it.
class HostLauncher(private val activity: Activity) {
    private var twa: TwaLauncher? = null

    fun launch(url: String) {
        if (!chromeInstalled()) {
            activity.startActivity(Intent(activity, HostActivity::class.java).putExtra(HostActivity.EXTRA_URL, url))
            return
        }
        twa?.destroy()
        val launcher = TwaLauncher(activity, CHROME)
        twa = launcher
        val builder = TrustedWebActivityIntentBuilder(Uri.parse(url))
            // Sticky immersive, kept out of the camera cutout (mode 0 = default).
            .setDisplayMode(TrustedWebActivityDisplayMode.ImmersiveMode(true, 0))
            .setScreenOrientation(ScreenOrientation.LANDSCAPE)
        launcher.launch(builder, null, null, null)
    }

    fun destroy() {
        twa?.destroy()
        twa = null
    }

    private fun chromeInstalled(): Boolean = try {
        activity.packageManager.getPackageInfo(CHROME, 0)
        true
    } catch (e: Exception) {
        false
    }

    companion object {
        const val CHROME = "com.android.chrome"
    }
}
