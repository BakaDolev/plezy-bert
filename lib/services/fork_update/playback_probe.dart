/// Reads what plays right now, for the fork's updater (fork-only; never upstream).
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../screens/video_player_screen.dart';
import '../music/music_playback_service.dart';
import '../pip_service.dart';
import 'update_gate.dart';

/// Whether an update must wait (see [isPlaybackActive]). Music is only seen
/// from inside a profile session, where its service lives.
bool isPlaybackActiveIn(BuildContext context) => isPlaybackActive(
  videoPlayerOpen: VideoPlayerScreenState.activeGlobalKey != null,
  musicStatus: context.read<MusicPlaybackService?>()?.status,
  pipActive: PipService().isPipActive.value,
);
