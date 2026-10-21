part of '../video_controls.dart';

extension _PlexVideoControlsPlaybackExtrasMethods on _PlexVideoControlsState {
  /// Re-keys the per-item chapters/markers/skip state when the screen's
  /// current item has moved. Runs from the current-item notifier (a swap that
  /// lands while the app is hidden) and from didUpdateWidget; whichever comes
  /// second finds the state already keyed to the item and keeps its extras.
  void _rekeyPlaybackExtrasIfItemChanged() {
    final itemKey = _activeItem.globalKey;
    if (itemKey == _extrasItemKey) return;
    _extrasItemKey = itemKey;
    // A pending skip is an offset into the outgoing item's timeline; letting
    // it survive would rebase the next press onto the previous episode. This
    // is the lifecycle backstop for every route that replaces the item
    // without going through a wrapped next/previous callback — natural
    // completion, a peer, an external change — so it also has to reach the
    // desktop timeline's own accumulator and the shared readout.
    _hiddenSeek.cancel();
    _desktopControlsKey.currentState?.abandonPendingSeek();
    _dismissSkipFeedback();
    _setControlsState(() {
      _chapters = [];
      _chaptersLoaded = false;
      _markers = [];
      _markersLoaded = false;
    });
    _clearCurrentMarker();
    _loadPlaybackExtras();
  }

  Future<void> _loadPlaybackExtras({bool forceRefresh = false}) async {
    // Live TV metadata uses EPG rating keys, not library items
    if (widget.isLive) return;
    final metadata = _activeItem;
    final loadKey = metadata.globalKey;
    // Re-entrancy guard is per item: an in-place episode swap may start the
    // new item's load while the old item's is still in flight.
    if (_isLoadingExtras && _extrasLoadKey == loadKey) return;
    _isLoadingExtras = true;
    _extrasLoadKey = loadKey;

    final serverId = metadata.serverId;
    // Read providers before any await — `context` after an async gap is
    // a lint trigger and can crash if the widget unmounts mid-load.
    final client = serverId != null ? context.tryGetMediaClientForServer(ServerId(serverId)) : null;
    final database = context.read<AppDatabase>();

    try {
      final extras = await VideoControlsPlaybackExtrasLoader(
        metadata: metadata,
        database: database,
        client: client,
      ).load(forceRefresh: forceRefresh);
      // Discard stale responses — the item may have swapped mid-flight.
      if (extras != null && mounted && _activeItem.globalKey == loadKey) {
        _applyPlaybackExtras(extras);
      }
    } finally {
      if (_extrasLoadKey == loadKey) _isLoadingExtras = false;
    }
  }

  void _applyPlaybackExtras(PlaybackExtras extras) {
    if (!mounted) return;
    _setControlsState(() {
      _chapters = extras.chapters;
      _markers = extras.markers;
      _chaptersLoaded = true;
      _markersLoaded = true;
    });
    _syncCurrentMarkerForCurrentPosition();
  }
}
