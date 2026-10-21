package com.edde746.plezy

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build

/**
 * Whether the system screensaver (a dream) is showing.
 *
 * A dream reaches the app only as a lifecycle stop, the same as leaving for
 * another app; the dream broadcasts tell the two apart, so a TV player paused
 * under the screensaver can keep its pipeline instead of releasing it and
 * reloading on wake. The broadcasts go to runtime-registered receivers only.
 */
internal class ScreensaverState : BroadcastReceiver() {
  @Volatile
  var isShowing: Boolean = false
    private set

  override fun onReceive(context: Context?, intent: Intent?) {
    when (intent?.action) {
      Intent.ACTION_DREAMING_STARTED -> isShowing = true
      Intent.ACTION_DREAMING_STOPPED -> isShowing = false
    }
  }

  fun register(context: Context) {
    val filter = IntentFilter().apply {
      addAction(Intent.ACTION_DREAMING_STARTED)
      addAction(Intent.ACTION_DREAMING_STOPPED)
    }
    // System broadcasts still reach a not-exported receiver.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      context.registerReceiver(this, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      context.registerReceiver(this, filter)
    }
  }

  fun unregister(context: Context) {
    try {
      context.unregisterReceiver(this)
    } catch (_: IllegalArgumentException) {
      // Never registered.
    }
    isShowing = false
  }
}
