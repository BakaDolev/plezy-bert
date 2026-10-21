package com.edde746.plezy.shared

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the Wi-Fi radio (and CPU) awake while phone background-audio playback
 * is active with the screen off.
 *
 * With the screen off, Android parks the Wi-Fi radio after a few minutes (and,
 * on aggressive OEM builds, dozes the process). That kills the long-lived HTTPS
 * stream to a LAN Plex/Jellyfin server — the `*.plex.direct` hostname stops
 * resolving (`ERR_NAME_NOT_RESOLVED`) and playback stalls until the screen is
 * turned back on. The media foreground service keeps the PROCESS alive but does
 * not keep the radio awake; only a [WifiManager.WifiLock] does. The partial
 * wake lock is belt-and-suspenders against Doze suspending the socket mid-read.
 * (mpv also reconnects a dropped stream — see MpvPlayerCore's `stream-lavf-o`
 * reconnect options — but preventing the drop is cheaper than recovering it.)
 *
 * Held only while backgrounded AND background-audio is armed; released on
 * surface restore / stop, so it never drains battery during normal use. Held by
 * the mpv core's background-audio path (surface loss -> vid=no). All calls are
 * idempotent and best-effort — a failure is logged, never thrown.
 */
class BackgroundNetworkLock(context: Context) {
  private val appContext = context.applicationContext
  private var wifiLock: WifiManager.WifiLock? = null
  private var wakeLock: PowerManager.WakeLock? = null

  @SuppressLint("WakelockTimeout") // released deterministically on foreground/stop, not by timeout
  fun acquire() {
    if (wifiLock?.isHeld == true) return
    try {
      // WIFI_MODE_FULL_HIGH_PERF (not FULL_LOW_LATENCY, which only engages in
      // the foreground) is the mode that keeps the radio awake while backgrounded.
      val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
      wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, WIFI_LOCK_TAG)?.apply {
        setReferenceCounted(false)
        acquire()
      }

      val power = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
      wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)?.apply {
        setReferenceCounted(false)
        acquire()
      }
      Log.d(TAG, "Acquired background network locks (wifi + cpu)")
    } catch (e: Exception) {
      Log.w(TAG, "Failed to acquire background network locks", e)
    }
  }

  fun release() {
    try {
      if (wifiLock?.isHeld == true) wifiLock?.release()
    } catch (e: Exception) {
      Log.w(TAG, "Failed to release wifi lock", e)
    }
    wifiLock = null
    try {
      if (wakeLock?.isHeld == true) wakeLock?.release()
    } catch (e: Exception) {
      Log.w(TAG, "Failed to release wake lock", e)
    }
    wakeLock = null
  }

  companion object {
    private const val TAG = "BackgroundNetworkLock"
    private const val WIFI_LOCK_TAG = "plezy:bg-audio-wifi"
    private const val WAKE_LOCK_TAG = "plezy:bg-audio-cpu"
  }
}
