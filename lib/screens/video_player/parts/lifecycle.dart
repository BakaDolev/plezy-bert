part of '../../video_player_screen.dart';

bool shouldPauseVideoForBackground({required bool isHandheld, required bool isTv, required bool isAutomotive}) =>
    isHandheld || isTv || isAutomotive;

/// How long a paused player on a phone or TV may sit in the background
/// (screensaver included) before it closes.
const Duration pausedAwayCloseAfter = Duration(minutes: 30);

enum PausedAwayStep { close, lookAgainLater, nothing }

/// What a player does when [pausedAwayCloseAfter] in the background is up:
/// back in front, nothing; still in use (background audio, picture-in-picture,
/// Watch Together), look again later; otherwise close.
PausedAwayStep pausedAwayStep({
  required AppLifecycleState? lifecycleState,
  required bool playing,
  required bool pip,
  required bool watchTogether,
}) {
  if (lifecycleState == AppLifecycleState.resumed || lifecycleState == AppLifecycleState.inactive) {
    return PausedAwayStep.nothing;
  }
  if (playing || pip || watchTogether) return PausedAwayStep.lookAgainLater;
  return PausedAwayStep.close;
}

/// How long the phone must stay backgrounded (screen-off audio) before the
/// next item is queued to load as a low-bitrate transcode. The delay keeps a
/// quick app-switch from changing quality; genuine falling-asleep listening
/// crosses it.
const Duration _backgroundAudioDownshiftGrace = Duration(seconds: 30);

/// The cap the screen-off stream drops to. The lowest table entry (~320 kbps,
/// H.264 — not the HEVC that wedges Samsung's background decoder), which holds
/// tens of minutes in the demuxer cache while the picture is off anyway.
const TranscodeQualityPreset _backgroundAudioQualityPreset = TranscodeQualityPreset.p240_320;

/// The quality the next item loads at during screen-off listening: [cap] once
/// a downshift is pending, unless [selected] already streams at or below it.
TranscodeQualityPreset backgroundAudioPresetForNextItem({
  required TranscodeQualityPreset selected,
  required bool downshiftPending,
  TranscodeQualityPreset cap = _backgroundAudioQualityPreset,
}) {
  if (!downshiftPending) return selected;
  final selectedKbps = selected.videoBitrateKbps;
  final capKbps = cap.videoBitrateKbps;
  if (selectedKbps != null && capKbps != null && selectedKbps <= capKbps) return selected;
  return cap;
}

/// Whether a not-playing player still reports `buffering` to the OS media
/// session, which keeps the background-audio foreground service promoted.
/// A `paused` report demotes it; Android 12+ won't let a background app
/// re-promote, and about a minute later the app's network is cut. So only a
/// real pause, or a finished item with nothing coming next, reports paused —
/// the end of an item that rolls into the next one is still playing.
bool backgroundAudioHoldsSession({
  required bool armed,
  required bool intentToPlay,
  required bool completed,
  required bool autoAdvancePending,
}) => armed && intentToPlay && (!completed || autoAdvancePending);

/// Whether a finished item is rolling into the next one on its own: auto-play
/// is on, a next item is known, nothing ([blocked]: no navigation, the
/// end-of-video sleep timer, the still-watching prompt) stops it, and the EOF
/// is either not handled yet or its advance is under way (Up Next countdown
/// running, next item loading). A handled EOF with neither was cancelled or
/// failed. The end of one file of a multi-part item with another part after it
/// ([stackedPartFollows]) is pending regardless: the same item continues.
bool completionAutoAdvancePending({
  required bool autoPlayEnabled,
  required bool hasNext,
  required bool blocked,
  required bool completionHandled,
  required bool countdownRunning,
  required bool loadingNext,
  required bool stackedPartFollows,
}) =>
    stackedPartFollows ||
    (autoPlayEnabled && hasNext && !blocked && (!completionHandled || countdownRunning || loadingNext));

/// Whether to rebuild the stream on return to the foreground: a transport
/// fault was logged during screen-off listening ([cacheEndAtBackgroundFault]
/// is the cache end it left) and no media has reached the cache since. A cut
/// network leaves mpv's reconnect loop backing off for minutes and a transcode
/// session reaped, so without a rebuild the unlocked player stalls; a fault
/// mpv recovered from on its own has grown the cache and is left alone. A
/// finished item ([itemFinished]) has nothing left to stream: the Up Next
/// countdown or the viewer decides what plays next, and a rebuild would only
/// reload its end. A stream the server stopped ([stoppedByServer], e.g. from
/// the Plex dashboard) stays stopped until the viewer resumes it.
bool shouldRebuildStreamOnResume({
  required Duration? cacheEndAtBackgroundFault,
  required Duration cacheEnd,
  required bool itemFinished,
  required bool stoppedByServer,
}) => !itemFinished && !stoppedByServer && cacheEndAtBackgroundFault != null && cacheEnd <= cacheEndAtBackgroundFault;

extension _VideoPlayerLifecycleMethods on VideoPlayerScreenState {
  void _enqueueLifecycleTransition(String label, Future<void> Function() transition) {
    _lifecycleTransition = _lifecycleTransition
        .catchError((Object error, StackTrace stackTrace) {
          appLogger.w('Previous lifecycle transition failed', error: error, stackTrace: stackTrace);
        })
        .then((_) async {
          if (!mounted || _shuttingDown) return;
          try {
            await transition();
          } catch (e, stackTrace) {
            appLogger.w('Lifecycle transition failed during $label', error: e, stackTrace: stackTrace);
          }
        });
  }

  void _recordLifecycleState(String state, {String? action}) {
    final isTv = PlatformDetector.isTV();
    final pipActive = PipService().isPipActive.value;
    final breadcrumbData = <String, dynamic>{
      'state': state,
      'isTv': isTv,
      'autoPipEnabled': _autoPipEnabled,
      'pipActive': pipActive,
      'pipTransitionInFlight': _androidAutoPipTransitionInFlight,
      'hiddenForBackground': _hiddenForBackground,
      'playerSuspendedForTvBackground': _tvSuspend.suspended,
      'mediaControlsSuspendedForTvBackground': _mediaControls.suspendedForTvBackground,
      'backend': _playerBackendLabel,
    };
    if (action != null) {
      breadcrumbData['action'] = action;
    }

    Sentry.addBreadcrumb(
      Breadcrumb(message: 'Player lifecycle $state', category: 'player.lifecycle', data: breadcrumbData),
    );

    appLogger.d(
      'Player lifecycle: state=$state'
      '${action != null ? ' action=$action' : ''}'
      ' isTv=$isTv'
      ' autoPipEnabled=$_autoPipEnabled'
      ' pipActive=$pipActive'
      ' pipTransitionInFlight=$_androidAutoPipTransitionInFlight'
      ' hiddenForBackground=$_hiddenForBackground'
      ' playerSuspendedForTvBackground=${_tvSuspend.suspended}'
      ' mediaControlsSuspendedForTvBackground=${_mediaControls.suspendedForTvBackground}'
      ' backend=$_playerBackendLabel',
    );
  }

  /// Whether the OS media session holds `buffering` while the player is not
  /// playing (see [backgroundAudioHoldsSession]). [completed] is the reporting
  /// player's end-of-file state.
  bool _backgroundAudioHoldsSession({required bool completed}) {
    final autoAdvancePending =
        completed &&
        _backgroundAudioArmed &&
        completionAutoAdvancePending(
          autoPlayEnabled: SettingsService.instanceOrNull?.read(SettingsService.autoPlayNextEpisode) ?? false,
          hasNext: _episode.next != null,
          blocked: !_canNavigateMediaItems() || SleepTimerService().isEndOfVideoMode || _showStillWatchingPrompt,
          completionHandled: _episode.completionLatch.triggered,
          countdownRunning: _episode.autoPlayTimer?.isActive == true,
          loadingNext: _episode.isLoadingNext,
          stackedPartFollows: !widget.isLive && (_currentMediaInfo?.partTimeline?.hasNext ?? false),
        );
    return backgroundAudioHoldsSession(
      armed: _backgroundAudioArmed,
      intentToPlay: _playbackIntentShouldPlay,
      completed: completed,
      autoAdvancePending: autoAdvancePending,
    );
  }

  void _setAndroidAutoPipTransitionInFlight(bool value, {required String reason}) {
    if (!Platform.isAndroid || _androidAutoPipTransitionInFlight == value) return;
    _androidAutoPipTransitionInFlight = value;
    _recordLifecycleState('pip_transition', action: '${value ? 'started' : 'cleared'}:$reason');
  }

  /// Arm the screen-off background-audio quality downshift (Android phone only).
  ///
  /// Full-bitrate direct play drains the demuxer cache in ~2 min, so a
  /// screen-off Wi-Fi/Doze network gap starves audio; once audio stops the media
  /// foreground service no longer counts as "playing" and Android freezes the
  /// process. Loading at [_backgroundAudioQualityPreset] makes the cache last
  /// tens of minutes and keeps audio flowing across those gaps. After
  /// [_backgroundAudioDownshiftGrace] the downshift is queued for the next item
  /// ([_qualityPresetForNextItem]) rather than applied mid-item: the next
  /// episode loads fresh anyway, while reloading the playing one silenced the
  /// audio for a few seconds. [_handleAppResumed] cancels it and restores the
  /// original quality.
  void _armBackgroundAudioQualityDownshift() {
    if (!Platform.isAndroid || widget.isLive || _offlineLibraryMode) return;
    _backgroundAudioDownshiftTimer?.cancel();
    _backgroundAudioDownshiftTimer = Timer(_backgroundAudioDownshiftGrace, () {
      _backgroundAudioDownshiftTimer = null;
      if (!mounted || _shuttingDown) return;
      // A resume cancels the timer, but it could have already been in flight as
      // the app returned to the foreground; skip the downshift in that case.
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
      _backgroundDownshiftPending = true;
      appLogger.d(
        'Background-audio: next item queued at ${_backgroundAudioQualityPreset.name} for screen-off listening',
      );
    });
  }

  void _cancelBackgroundAudioQualityDownshift() {
    _backgroundAudioDownshiftTimer?.cancel();
    _backgroundAudioDownshiftTimer = null;
    _backgroundDownshiftPending = false;
  }

  /// The preset the next item loads at: the background cap while a screen-off
  /// downshift is pending, remembering the current quality for the resume
  /// restore; otherwise the selected quality.
  TranscodeQualityPreset _qualityPresetForNextItem() {
    final selected = _selectedQualityPreset;
    final preset = backgroundAudioPresetForNextItem(selected: selected, downshiftPending: _backgroundDownshiftPending);
    if (preset != selected) {
      _backgroundDownshiftRestorePreset ??= selected;
      appLogger.d('Background-audio: loading the next item at ${preset.name} for screen-off listening');
    }
    return preset;
  }

  /// Returns whether it reloaded the stream.
  Future<bool> _restoreQualityAfterBackgroundAudio() async {
    final restore = _backgroundDownshiftRestorePreset;
    if (restore == null) return false;
    _backgroundDownshiftRestorePreset = null;
    if (!mounted || _shuttingDown || !_isPlayerInitialized || player == null) return false;
    if (widget.isLive || _selectedQualityPreset == restore) return false;
    try {
      await _switchPlaybackSource(newPreset: restore);
      appLogger.d('Background-audio: restored quality to ${restore.name} after resume');
      return true;
    } catch (e) {
      appLogger.w('Restore quality after background audio failed', error: e);
      return false;
    }
  }

  /// Latch a transport fault logged during screen-off listening, with the
  /// cache end it left (see [shouldRebuildStreamOnResume]).
  void _noteBackgroundTransportFault() {
    if (!_backgroundAudioArmed || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _backgroundFaultCacheEnd = player?.state.buffer;
  }

  /// Back in the foreground: return to the pre-background quality if the
  /// screen-off downshift applied (a fresh stream either way), otherwise
  /// rebuild a stream that died while backgrounded.
  Future<void> _recoverStreamAfterBackgroundAudio() async {
    final faultCacheEnd = _backgroundFaultCacheEnd;
    _backgroundFaultCacheEnd = null;
    final cacheEnd = player?.state.buffer ?? Duration.zero;
    if (await _restoreQualityAfterBackgroundAudio()) return;
    if (!mounted || _shuttingDown || !_isPlayerInitialized) return;
    final itemFinished = _episode.completionLatch.triggered;
    final stoppedByServer = _progressTracker?.stoppedByServer ?? false;
    if (!shouldRebuildStreamOnResume(
      cacheEndAtBackgroundFault: faultCacheEnd,
      cacheEnd: cacheEnd,
      itemFinished: itemFinished,
      stoppedByServer: stoppedByServer,
    )) {
      if (faultCacheEnd != null) {
        appLogger.d(
          'Background-audio: no rebuild after a background fault '
          '(recovered=${cacheEnd > faultCacheEnd} finished=$itemFinished stoppedByServer=$stoppedByServer)',
        );
      }
      return;
    }
    await _eofRecovery.retry(reason: 'stream lost while backgrounded');
  }

  Future<void> _handleAppHidden() async {
    if (_shouldSkipForPip) {
      _recordLifecycleState('hidden', action: 'skipped_for_pip');
      return;
    }

    // Suppress Watch Together heartbeats while backgrounded so App Nap
    // doesn't cause stale position broadcasts that make guests loop.
    _watchTogetherProvider?.setBackgrounded(true);

    final currentPlayer = player;
    if (currentPlayer == null || !_isPlayerInitialized) {
      _recordLifecycleState('hidden', action: 'skipped_no_player');
      return;
    }

    final isTv = PlatformDetector.isTV();
    if (widget.isLive && shouldStopLiveSessionForTvBackground(isTv: isTv, policy: _live.session?.backgroundPolicy)) {
      _stopLiveSessionForTvBackground();

      // Start the server cleanup before releasing the native stream. tvOS may
      // suspend the process shortly after this lifecycle callback returns.
      final stoppedReport = _sendStoppedProgressOnce();
      try {
        await currentPlayer.stop();
      } catch (e, stackTrace) {
        appLogger.w('Failed to stop live player while backgrounding', error: e, stackTrace: stackTrace);
      }
      await stoppedReport;
      if (!mounted || _shuttingDown || currentPlayer != player) return;
      await _mediaControls.suspendForTvBackground('hidden_live_stopped');
      _recordLifecycleState('hidden', action: 'live_stopped_exit_on_resume');
      return;
    }

    final isAutomotive = PlatformDetector.isAutomotive();
    final shouldPauseForBackground = shouldPauseVideoForBackground(
      isHandheld: PlatformDetector.isMobile(context),
      isTv: isTv,
      isAutomotive: isAutomotive,
    );

    // Phone + VOD + opt-in: keep audio playing in the background instead of
    // pausing/hiding. Overrides the handheld pause below and rides the OS media
    // foreground service (see [shouldPlayVideoInBackground]).
    final playInBackground = shouldPlayVideoInBackground(
      isAndroid: Platform.isAndroid,
      isHandheld: PlatformDetector.isMobile(context),
      isTv: isTv,
      isAutomotive: isAutomotive,
      isLive: widget.isLive,
      settingEnabled: SettingsService.instanceOrNull?.read(SettingsService.backgroundPlayback) ?? true,
    );

    // Pause first so Android MPV does not keep decoding against a transient
    // background surface while the app is locking or hiding.
    if (shouldPauseForBackground && !playInBackground) {
      // Sticky latch: a car with the Automotive compatibility mode delivers
      // onPause *and* onStop, so this runs twice, and the second pass must not
      // overwrite the latch with the already-paused state. Cleared on resume.
      final wasActive = currentPlayer.state.isActive;
      _wasPlayingBeforeInactive = _wasPlayingBeforeInactive || wasActive;
      if (wasActive) {
        try {
          // On a car this is the driving transition itself, on every head unit whose vehicle cannot
          // report its restrictions. It is forced on this peer alone, so it must not travel to the
          // rest of a Watch Together room; elsewhere backgrounding keeps its existing meaning.
          if (isAutomotive) {
            if (await _pauseWithoutDisturbingTheRoom(currentPlayer)) {
              // The sync layer owns this pause and its resume. Drop the latch so the screen does not
              // also restore playback on the way back and ask the room to play along with it.
              _wasPlayingBeforeInactive = false;
            }
          } else {
            await _pauseWithPlaybackIntent(currentPlayer);
          }
          appLogger.d(
            'Video paused due to app being hidden '
            '(${isAutomotive
                ? 'automotive'
                : isTv
                ? 'tv'
                : 'handheld'})',
          );
        } catch (e) {
          appLogger.w('Failed to pause video before background transition', error: e);
        }
      }
    }

    if (!mounted || _shuttingDown || currentPlayer != player) return;

    _suspendLiveTimelineForBackground();
    _armPausedAwayClose();

    if (playInBackground) {
      // Keep audio playing in the background. The mpv core is already armed to
      // drop video (vid=no) on surface loss instead of pausing, and the OS media
      // foreground service + MediaStyle notification are already running — both
      // set up at playback open in `_syncVideoBackgroundMode` (in the
      // foreground, so the FGS starts legally on Android 12+ and the native
      // arming is set before the surface is ever lost). Nothing to do on the way
      // out except skip the render-hide and the TV/handheld paths below, and
      // arm the screen-off quality downshift so the demuxer cache lasts across
      // Wi-Fi/Doze network gaps (see [_armBackgroundAudioQualityDownshift]).
      _armBackgroundAudioQualityDownshift();
      _recordLifecycleState('hidden', action: 'background_audio');
      return;
    }

    if (isTv) {
      await _mediaControls.suspendForTvBackground('hidden');
      if (_armTvBackgroundPlayerSuspendTimer()) {
        _recordLifecycleState('hidden', action: 'tv_background_pause_suspend_armed');
      } else {
        _recordLifecycleState('hidden', action: 'tv_background_pause_only');
      }
      return;
    }

    _hiddenForBackground = true;
    await currentPlayer.setVisible(false, restoreOnWindowVisible: Platform.isMacOS);
    _recordLifecycleState('hidden', action: 'render_hidden');
  }

  /// A phone or TV player left paused in the background (a TV's screensaver
  /// counts) for [pausedAwayCloseAfter] closes, ending its session and its
  /// paused heartbeats; reopening the item resumes from the server's spot,
  /// wherever the viewer got to meanwhile. A TV's player may already be
  /// released by the background suspend; this then leaves the player screen
  /// too. Still playing (background audio), in picture-in-picture or in Watch
  /// Together, it looks again later. Desktop players stay open.
  void _armPausedAwayClose() {
    _pausedAwayCloseTimer?.cancel();
    if (widget.isLive || !(Platform.isAndroid || Platform.isIOS)) return;
    _pausedAwayCloseTimer = Timer(pausedAwayCloseAfter, () {
      final currentPlayer = player;
      if (!mounted || _shuttingDown || currentPlayer == null) return;
      switch (pausedAwayStep(
        lifecycleState: WidgetsBinding.instance.lifecycleState,
        playing: currentPlayer.state.isActive,
        pip: PipService().isPipActive.value,
        watchTogether: _watchTogetherProvider?.isInSession ?? false,
      )) {
        case PausedAwayStep.nothing:
          return;
        case PausedAwayStep.lookAgainLater:
          _armPausedAwayClose();
        case PausedAwayStep.close:
          _recordLifecycleState('hidden', action: 'paused_away_close');
          unawaited(_exitPlayerRoute(navigateHome: false));
      }
    });
  }

  Future<void> _handleAppResumed() async {
    if (_shuttingDown) return;
    _recordLifecycleState('resumed', action: 'begin');
    _watchTogetherProvider?.setBackgrounded(false);
    // Stop a pending screen-off downshift from firing during resume; the
    // restore below returns quality if the downshift already applied.
    _cancelBackgroundAudioQualityDownshift();

    if (_consumeLiveExitOnResume()) {
      _recordLifecycleState('resumed', action: 'exit_stopped_live_session');
      await _handleBackButton();
      return;
    }

    if (Platform.isAndroid && _androidAutoPipTransitionInFlight && !PipService().isPipActive.value) {
      _setAndroidAutoPipTransitionInFlight(false, reason: 'resume_without_pip');
    }

    final currentPlayer = player;

    // Background audio mode (native arming + OS foreground service) is left
    // running for the whole session and torn down at dispose, mirroring the
    // music service — so there is nothing to disarm here. On resume the OS
    // re-attaches the real surface and mpv re-primes video (vid=auto in
    // refreshVideoOutput). If the render layer was hidden (non-background path),
    // restore it below.

    // Restore render layer if it was hidden for background, then force a
    // video-output refresh before any auto-resume logic runs.
    if (_hiddenForBackground && currentPlayer != null && _isPlayerInitialized) {
      await currentPlayer.setVisible(true);
      if (!Platform.isMacOS) {
        await currentPlayer.updateFrame();
      }

      if (!mounted || _shuttingDown || currentPlayer != player) return;

      _hiddenForBackground = false;
      _recordLifecycleState('resumed', action: 'render_restored');
    }

    // A TV background suspend released the native pipeline via stop();
    // rebuild the playback session in place before the media-control restore
    // below can act on the stopped player.
    if (_tvSuspend.suspended) {
      await _restorePlayerAfterTvBackgroundSuspend();
      if (!mounted || _shuttingDown || currentPlayer != player) return;
    }
    // TV never hides the render layer on background (_handleAppHidden returns
    // early without setting _hiddenForBackground), but the screensaver can
    // still destroy the surface. Kick the video output so a missed surface
    // callback can't leave the picture black: mpv re-attaches via
    // refreshVideoOutput, ExoPlayer just reapplies sizing/z-order.
    else if (!_hiddenForBackground &&
        Platform.isAndroid &&
        PlatformDetector.isTV() &&
        currentPlayer != null &&
        _isPlayerInitialized) {
      await currentPlayer.updateFrame();
      if (!mounted || _shuttingDown || currentPlayer != player) return;
      _recordLifecycleState('resumed', action: 'tv_video_output_kick');
    }

    // Restore media controls and wakelock when app is resumed.
    if (_isPlayerInitialized && mounted && !_shuttingDown) {
      _mediaControls.resumeAfterTvBackground('app_resumed');
      await _mediaControls.restoreAfterResume();
    }

    // Return to the pre-background quality if the screen-off downshift applied,
    // or rebuild a stream that died while backgrounded.
    unawaited(_recoverStreamAfterBackgroundAudio());

    _resumeLiveTimelineAfterBackgroundIfNeeded();
    _recordLifecycleState('resumed', action: 'complete');
  }

  /// Arm the grace timer that releases the native AV pipeline if the app
  /// stays backgrounded (Android TV only). Returns whether it was armed.
  bool _armTvBackgroundPlayerSuspendTimer() {
    if (_shuttingDown) return false;
    if (!shouldSuspendPlayerForTvBackground(
      isAndroid: Platform.isAndroid,
      isTv: PlatformDetector.isTV(),
      isLive: widget.isLive,
      alreadySuspended: _tvSuspend.suspended,
    )) {
      return false;
    }
    _tvSuspend.armGrace(() {
      _enqueueLifecycleTransition('tv_background_suspend', _suspendPlayerForTvBackground);
    });
    return true;
  }

  void _cancelTvBackgroundPlayerSuspendTimer() {
    _tvSuspend.cancelGrace();
  }

  /// Grace expired while still backgrounded: release the native AV pipeline
  /// (MediaCodec decoders + AudioTrack, tunneled passthrough included) so a
  /// parked Plezy can't starve other apps on shared-hardware TV SoCs, and end
  /// the backend playback session. Fire OS standby never freezes the process,
  /// so paused heartbeats would pin the session in the server dashboard for
  /// as long as the device sits dark (#1911) — and they buy nothing here: the
  /// restore path performs a fresh playback decision and rebuilds progress
  /// reporting anyway. stop() retains Dart-side position/duration/track state
  /// on both Android backends; position and track selections are latched here
  /// because the reload on restore reads them after the native state is gone.
  Future<void> _suspendPlayerForTvBackground() async {
    // The screensaver is a nap, not a departure: the viewer wakes the TV
    // straight back into this paused player, and a release would make them
    // sit through a full reload. Hold it while the dream shows; leaving from
    // there (Home, standby) ends the dream and a later grace releases as usual.
    if (Platform.isAndroid && await isScreensaverShowing()) {
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      final stillHidden = lifecycleState != AppLifecycleState.resumed && lifecycleState != AppLifecycleState.inactive;
      if (mounted && !_shuttingDown && stillHidden && _armTvBackgroundPlayerSuspendTimer()) {
        _recordLifecycleState('hidden', action: 'tv_background_suspend_held_for_screensaver');
      }
      return;
    }
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null || !_isPlayerInitialized) return;
    // A live stream's tuned session is also its time-shift buffer. Stopping
    // it would force a re-tune at the live edge and discard pause state.
    if (widget.isLive) return;
    if (_tvSuspend.suspended || _shouldSkipForPip) return;
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.resumed || lifecycleState == AppLifecycleState.inactive) return;
    if (_transitionGate.transition != PlaybackTransition.idle || !_firstFrame.uiReady.value) {
      // A reload/zap/startup flow owns the player right now; stopping under
      // it would corrupt its open sequence. Retry after another grace.
      _armTvBackgroundPlayerSuspendTimer();
      return;
    }

    final suspendPosition = currentPlayer.state.position;
    final suspendDuration = currentPlayer.state.duration;
    _tvSuspend.latch(
      position: suspendPosition,
      audioTrack: currentPlayer.state.track.audio,
      subtitleTrack: currentPlayer.state.track.subtitle,
      secondarySubtitleTrack: currentPlayer.state.track.secondarySubtitle,
    );
    _tvSuspendedMetadata = _currentMetadata;
    // A Play Next countdown only holds while the app counts as backgrounded;
    // returning before the restore runs would let it advance over a released
    // player. The restore puts it back once the item has reopened.
    _episode.autoPlayTimer?.cancel();
    // Stop the heartbeat timer first: its paused tick also pings any Plex
    // transcode session, which would keep that alive past the stop report.
    // Start the stopped report before releasing the native stream — the same
    // ordering as the live background path and the reload flow, because
    // stop() resets player state the report would otherwise read. The
    // one-shot latch coalesces this stop with the one the restore reload
    // sends before re-resolving the source.
    _progressTracker?.stopTracking();
    final stoppedReport = _sendStoppedProgressOnce(positionOverride: suspendPosition);
    try {
      await currentPlayer.stop();
      _recordLifecycleState('hidden', action: 'tv_background_suspend');
    } catch (e) {
      _tvSuspend.clear();
      _tvSuspendedMetadata = null;
      if (_episode.showPlayNextDialog && _episode.autoPlayCountdown.value > 0) _startAutoPlayTimer();
      // The player still holds its native state, so re-arm reporting: the
      // next paused heartbeat re-opens a server session at the same position
      // and the pause stays resumable in place.
      await stoppedReport;
      if (_shuttingDown) return;
      _progressTracker?.resumeAfterStoppedReport();
      _progressTracker?.startTracking();
      appLogger.w('TV background suspend failed; player left paused', error: e);
      return;
    }
    // stop() releases the pipeline but leaves the display mode; a parked TV
    // must hand the panel back to the launcher's mode, as dispose does. The
    // restore reload re-runs the frame-rate startup plan for the next open.
    if (mounted && !_shuttingDown && player == currentPlayer && !currentPlayer.disposed) {
      try {
        await currentPlayer.clearVideoFrameRate();
      } catch (e) {
        appLogger.w('TV background suspend: failed to clear the display mode', error: e);
      }
    }
    await stoppedReport;
    if (!(_progressTracker?.stoppedReportDelivered ?? true)) {
      unawaited(_redeliverTvBackgroundStopReport(position: suspendPosition, duration: suspendDuration));
    }
  }

  /// Bounded redelivery of the suspend-time stopped report. Standby entry can
  /// drop Wi-Fi into power-save and stall exactly that connect, and mutations
  /// deliberately never fail over ([FailoverHttpClient]) — a lost terminal
  /// report would leave the server session pinned, the very state the suspend
  /// exists to clear (#1911). Runs detached from the lifecycle transition
  /// queue so a wake-up is never blocked behind a backoff sleep; each attempt
  /// re-checks that the suspend is still standing, because the restore path
  /// drops the suspended latch before it rebuilds a live session that a late
  /// retry must not report stopped.
  Future<void> _redeliverTvBackgroundStopReport({required Duration position, required Duration duration}) async {
    for (var attempt = 0; attempt < TvBackgroundSuspendState.stopReportMaxRetries; attempt++) {
      await Future<void>.delayed(TvBackgroundSuspendState.stopReportRetryDelay);
      final tracker = _progressTracker;
      if (!mounted || _shuttingDown || tracker == null || !_tvSuspend.suspended) return;
      if (tracker.stoppedReportDelivered) return;
      await tracker.sendProgress('stopped', positionOverride: position, durationOverride: duration);
    }
  }

  /// Rebuild the playback session after a TV background suspend released the
  /// native pipeline and reported the backend session stopped. VOD reloads in
  /// place through the regular reload flow — a fresh playback decision, since
  /// the old session is closed and its stream URL may have expired
  /// server-side — and comes back paused; the caller's
  /// [MediaControlsScreenController.restoreAfterResume] then resumes it (with
  /// rewind-on-resume) exactly like a plain background pause. Live sessions
  /// never enter this flow because their tuned session and capture-buffer
  /// position must remain intact across backgrounding.
  Future<void> _restorePlayerAfterTvBackgroundSuspend() async {
    final restore = _tvSuspend.consumeForRestore();
    final suspendedMetadata = _tvSuspendedMetadata;
    _tvSuspendedMetadata = null;

    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null || !_isPlayerInitialized) return;
    if (suspendedMetadata == null || suspendedMetadata.globalKey != _currentMetadata.globalKey) {
      // The viewer moved to another item while the suspend was settling; that
      // item's own open already replaced the released stream.
      _recordLifecycleState('resumed', action: 'tv_background_suspend_restore_skipped_item_changed');
      return;
    }

    // The countdown holds while backgrounded, so a suspend can land with the
    // Play Next prompt up. The reload below clears the prompt; without it the
    // finished episode parks at its last frame with nothing to advance it.
    final playNextCountdown = _episode.showPlayNextDialog ? _episode.autoPlayCountdown.value : null;

    _recordLifecycleState('resumed', action: 'tv_background_suspend_reload');
    final outcome = await _reloadMediaInPlace(
      metadata: _currentMetadata,
      resumePosition: restore.position,
      preserveCurrentTrackSelection: true,
      preservedAudioTrack: restore.audioTrack,
      preservedSubtitleTrack: SubtitlePreference.trackOrNull(restore.subtitleTrack),
      preservedSecondarySubtitleTrack: SubtitlePreference.trackOrNull(restore.secondarySubtitleTrack),
      startPaused: true,
      // A failure raises the failure view below instead: a snackbar would sit
      // over a player whose pipeline the suspend already released.
      showErrorUi: false,
      reason: 'TV background suspend restore',
    );
    if (outcome == MediaReloadOutcome.opened) {
      // The suspend closed the session at this spot; another device may have
      // played on since. If so, the play that follows asks where to go on from.
      final suspendPosition = restore.position;
      if (suspendPosition != null) {
        await _progressTracker?.newerProgress?.recheckAfterClose(suspendPosition);
      }
      if (playNextCountdown != null) await _restorePlayNextPrompt(countdown: playNextCountdown);
    } else if (outcome == MediaReloadOutcome.rejected) {
      appLogger.w('TV background suspend restore: in-place reload rejected');
    } else if (outcome == MediaReloadOutcome.failed) {
      appLogger.w('TV background suspend restore: in-place reload failed');
      // The rollback kept the suspended session, which stop() left with
      // nothing to play; Retry re-runs the open from the playhead.
      if (mounted && _playbackFailureMessage == null) _presentPlaybackFailure(t.messages.playbackFailed);
    }
  }
}
