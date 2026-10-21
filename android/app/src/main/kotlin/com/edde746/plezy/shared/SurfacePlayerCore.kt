package com.edde746.plezy.shared

/**
 * Surface and display concerns that the ExoPlayer and mpv cores implement
 * identically, so a plugin holding either one dispatches without branching
 * on which backend is active.
 *
 * Only backend-independent members belong here: playback control
 * (play/seek/track selection) stays off this interface because mpv drives it
 * through properties and commands where ExoPlayer uses direct method calls.
 */
interface SurfacePlayerCore {
  fun setVisible(visible: Boolean)
  fun updateFrame()

  /**
   * Arm/disarm phone background-audio mode. When armed, a core that would
   * otherwise pause on losing its render surface (mpv) instead keeps decoding
   * audio with video output disabled, so screen-off playback continues.
   * ExoPlayer already keeps audio without a surface, so its implementation is a
   * no-op. Armed on the background transition; scoped to the phone-background
   * predicate so TV/automotive/desktop are never armed.
   */
  fun setBackgroundAudioMode(enabled: Boolean)
  fun onPipModeChanged(isInPipMode: Boolean)
  fun requestAudioFocus(): Boolean
  fun abandonAudioFocus()
  fun clearVideoFrameRate()
  fun setVideoFrameRate(
    fps: Float,
    videoDurationMs: Long,
    extraDelayMs: Long,
    videoWidth: Int,
    videoHeight: Int,
    matchResolution: Boolean,
    onComplete: (switched: Boolean) -> Unit
  )
}
