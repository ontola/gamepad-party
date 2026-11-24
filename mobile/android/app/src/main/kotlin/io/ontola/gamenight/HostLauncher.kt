package io.ontola.gamenight

import android.app.Activity
import android.app.NativeActivity
import android.content.pm.PackageManager
import android.os.Build
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
///
/// First choice: the native host in this app (android.app.NativeActivity
/// in the ":host" process running libsplitscreen_host.so, the Warp engine
/// itself with Vulkan instead of the browser; warp-game-engine
/// lobbies/game-room/android). It gets the browser host's query string as
/// its "query" extra and downloads the games from splitscreen.club/play/.
/// Needs the library in this build (BuildConfig.NATIVE_HOST), an arm64
/// phone and Vulkan 1.1.
class HostLauncher(private val activity: Activity) {
    private var twa: TwaLauncher? = null

    fun launch(url: String) {
        if (launchNative(url)) return
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

    private fun launchNative(url: String): Boolean {
        if (!nativeHostRuns()) return false
        val intent = Intent(activity, NativeActivity::class.java)
            .putExtra("query", Uri.parse(url).encodedQuery ?: "")
        return try {
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun nativeHostRuns(): Boolean =
        BuildConfig.NATIVE_HOST &&
            Build.SUPPORTED_ABIS.contains("arm64-v8a") &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION, VULKAN_1_1)

    private fun chromeInstalled(): Boolean = try {
        activity.packageManager.getPackageInfo(CHROME, 0)
        true
    } catch (e: Exception) {
        false
    }

    companion object {
        const val CHROME = "com.android.chrome"
        const val VULKAN_1_1 = 0x401000
    }
}
