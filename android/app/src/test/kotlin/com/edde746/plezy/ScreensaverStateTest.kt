package com.edde746.plezy

import android.content.Intent
import android.os.Looper
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class ScreensaverStateTest {
  private val context get() = RuntimeEnvironment.getApplication()

  private fun broadcast(action: String) {
    context.sendBroadcast(Intent(action))
    shadowOf(Looper.getMainLooper()).idle()
  }

  @Test
  @Config(sdk = [34])
  fun followsTheDreamBroadcastsOnceRegistered() {
    val state = ScreensaverState()
    state.register(context)
    assertFalse(state.isShowing)

    broadcast(Intent.ACTION_DREAMING_STARTED)
    assertTrue("a started dream is the screensaver showing", state.isShowing)

    broadcast(Intent.ACTION_DREAMING_STOPPED)
    assertFalse("a stopped dream is the screensaver gone", state.isShowing)
    state.unregister(context)
  }

  @Test
  @Config(sdk = [28])
  fun followsTheDreamBroadcastsBeforeTheExportFlagExisted() {
    val state = ScreensaverState()
    state.register(context)

    broadcast(Intent.ACTION_DREAMING_STARTED)
    assertTrue(state.isShowing)
    state.unregister(context)
  }

  @Test
  @Config(sdk = [34])
  fun forgetsTheDreamOnceUnregistered() {
    val state = ScreensaverState()
    state.register(context)
    broadcast(Intent.ACTION_DREAMING_STARTED)

    state.unregister(context)
    assertFalse("an unregistered tracker cannot vouch for the dream", state.isShowing)

    broadcast(Intent.ACTION_DREAMING_STARTED)
    assertFalse(state.isShowing)
  }
}
