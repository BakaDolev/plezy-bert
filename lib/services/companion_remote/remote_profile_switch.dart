import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/plex_home_switch.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_activation.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../base_shared_preferences_service.dart';
import '../playback_coordinator.dart';

/// Outcome of a remote `switchProfile`, sent back as `switchProfileResult`.
///
/// `verified` is sent BEFORE the switch: the switch replaces the profile
/// session, which closes the controller's connection, so the controller reads
/// the result from the `syncState` the new session sends when it reconnects.
enum RemoteSwitchStatus { verified, already, wrongPin, lockedOut, rateLimited, noSuchProfile, ambiguous, busy, failed }

/// Where the guard keeps its counters (persisted, so a relaunch can't reset them).
abstract interface class RemoteSwitchGuardStore {
  Future<String?> read();
  Future<void> write(String value);
}

class _PrefsGuardStore implements RemoteSwitchGuardStore {
  static const _key = 'companion_remote_switch_guard';

  @override
  Future<String?> read() async => (await BaseSharedPreferencesService.sharedCache()).getString(_key);

  @override
  Future<void> write(String value) async => (await BaseSharedPreferencesService.sharedCache()).setString(_key, value);
}

/// App-wide brake on guessing a profile PIN over the remote.
///
/// Every Home member can derive the remote's secret, so this is what stops a
/// 4-digit PIN being guessed: wrong PINs lock remote switching (3 → 5 min,
/// 6 → 1 h, 10 and on → 24 h), every attempt is rate limited, and the counts
/// live in preferences so a reconnect or a relaunch doesn't reset them. Only
/// a correct PIN for a protected profile clears them.
class RemoteSwitchGuard {
  RemoteSwitchGuard({RemoteSwitchGuardStore? store, DateTime Function()? now})
    : _store = store ?? _PrefsGuardStore(),
      _now = now ?? DateTime.now;

  static const minInterval = Duration(seconds: 3);

  final RemoteSwitchGuardStore _store;
  final DateTime Function() _now;
  bool _loaded = false;
  int _failures = 0;
  DateTime? _lockedUntil;
  DateTime? _lastAttempt;

  int get failures => _failures;
  DateTime? get lockedUntil => _lockedUntil;

  static Duration lockoutAfter(int failures) {
    if (failures >= 10) return const Duration(hours: 24);
    if (failures >= 6) return const Duration(hours: 1);
    if (failures >= 3) return const Duration(minutes: 5);
    return Duration.zero;
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _store.read();
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map) return;
      _failures = (json['failures'] as num?)?.toInt() ?? 0;
      final until = (json['lockedUntilMs'] as num?)?.toInt();
      _lockedUntil = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    } catch (e) {
      appLogger.w('Remote profile switch: guard state unreadable', error: e);
    }
  }

  Future<void> _save() async {
    try {
      await _store.write(jsonEncode({'failures': _failures, 'lockedUntilMs': _lockedUntil?.millisecondsSinceEpoch}));
    } catch (e) {
      appLogger.w('Remote profile switch: guard state not saved', error: e);
    }
  }

  /// Null when an attempt may go ahead (it then counts toward the rate
  /// limit); otherwise why it may not.
  Future<RemoteSwitchStatus?> admit() async {
    await _load();
    final now = _now();
    final until = _lockedUntil;
    if (until != null && now.isBefore(until)) return RemoteSwitchStatus.lockedOut;
    final last = _lastAttempt;
    if (last != null && now.difference(last) < minInterval) return RemoteSwitchStatus.rateLimited;
    _lastAttempt = now;
    return null;
  }

  /// Counts a wrong PIN; true when it starts a lockout.
  Future<bool> recordWrongPin() async {
    await _load();
    _failures++;
    final locks = _failures >= 10 || _failures % 3 == 0;
    if (locks) _lockedUntil = _now().add(lockoutAfter(_failures));
    await _save();
    return locks;
  }

  /// A correct PIN for a protected profile.
  Future<void> recordPinAccepted() async {
    await _load();
    if (_failures == 0 && _lockedUntil == null) return;
    _failures = 0;
    _lockedUntil = null;
    await _save();
  }
}

/// The profile a `switchProfile` names: by `profileId`, else `userUuid` (Plex
/// Home user), else `name` (case-insensitive). Exactly one must match.
({Profile? profile, RemoteSwitchStatus? error}) resolveRemoteSwitchTarget(
  List<Profile> profiles,
  Map<String, dynamic> data,
) {
  String? text(String key) {
    final value = data[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  final profileId = text('profileId');
  final userUuid = text('userUuid')?.toLowerCase();
  final name = text('name')?.toLowerCase();
  final List<Profile> matches;
  if (profileId != null) {
    matches = profiles.where((p) => p.id == profileId).toList();
  } else if (userUuid != null) {
    matches = profiles.where((p) => p.plexHomeUserUuid?.toLowerCase() == userUuid).toList();
  } else if (name != null) {
    matches = profiles.where((p) => p.displayName.trim().toLowerCase() == name).toList();
  } else {
    matches = const [];
  }
  if (matches.isEmpty) return (profile: null, error: RemoteSwitchStatus.noSuchProfile);
  if (matches.length > 1) return (profile: null, error: RemoteSwitchStatus.ambiguous);
  return (profile: matches.single, error: null);
}

/// Whether [profile] needs a PIN to switch to it.
bool remoteSwitchNeedsPin(Profile profile) => profile.isPlexHome ? profile.plexProtected : profile.isPinProtected;

typedef RemotePinMint =
    Future<PlexHomeSwitchResult> Function({
      required PlexAccountConnection account,
      required String homeUserUuid,
      required bool requiresPin,
      required PlexHomeSwitchPinPrompt promptForPin,
      ProfileConnectionRegistry? persistTo,
      String? persistProfileId,
      String? logLabel,
    });

/// Checks [pin] for [profile] without activating anything, and without ever
/// opening a PIN dialog.
///
/// Plex Home profiles always go through `/home/users/{uuid}/switch` (one
/// attempt: the supplier hands over [pin] once and answers any second ask —
/// Plex saying the PIN was wrong — with null). The minted token is persisted
/// and the profile marked pre-verified, so the binder reuses it instead of
/// minting again with its own dialog. Local profiles check their PIN hash.
Future<RemoteSwitchStatus> verifyRemoteProfilePin({
  required Profile profile,
  required String? pin,
  required Future<List<Connection>> Function() listConnections,
  required ProfileConnectionRegistry? persistTo,
  required void Function(String profileId) markPreVerified,
  RemotePinMint mint = mintPlexHomeUserToken,
}) async {
  if (profile.isPlexHome) {
    final parentId = profile.parentConnectionId;
    final homeUuid = profile.plexHomeUserUuid;
    if (parentId == null || homeUuid == null) return RemoteSwitchStatus.failed;
    PlexAccountConnection? account;
    for (final connection in await listConnections()) {
      if (connection.id == parentId && connection is PlexAccountConnection) {
        account = connection;
        break;
      }
    }
    if (account == null) return RemoteSwitchStatus.failed;
    var asks = 0;
    final result = await mint(
      account: account,
      homeUserUuid: homeUuid,
      requiresPin: profile.plexProtected,
      promptForPin: ({String? errorMessage}) async => ++asks == 1 ? pin : null,
      persistTo: persistTo,
      persistProfileId: persistTo == null ? null : profile.id,
      logLabel: profile.displayName,
    );
    switch (result.status) {
      case PlexHomeSwitchStatus.success:
        markPreVerified(profile.id);
        return RemoteSwitchStatus.verified;
      case PlexHomeSwitchStatus.cancelled:
        // Only the supplier cancels: Plex asked again (wrong PIN) or a
        // protected profile came with no PIN.
        return RemoteSwitchStatus.wrongPin;
      case PlexHomeSwitchStatus.failed:
      case PlexHomeSwitchStatus.authRejected:
        return RemoteSwitchStatus.failed;
    }
  }
  if (profile.isPinProtected) {
    return pin != null && verifyProfilePin(profile, pin) ? RemoteSwitchStatus.verified : RemoteSwitchStatus.wrongPin;
  }
  return RemoteSwitchStatus.verified;
}

/// What the remote is told about a profile (never its PIN).
Map<String, Object?> describeRemoteProfile(Profile profile) => {
  'id': profile.id,
  'name': profile.displayName,
  if (profile.plexHomeUserUuid != null) 'userUuid': profile.plexHomeUserUuid,
};

/// What a remote switch needs from the app; [RemoteSwitchEnv.fromContext] in
/// the app, fakes in tests.
class RemoteSwitchEnv {
  const RemoteSwitchEnv({
    required this.profiles,
    required this.activeId,
    required this.activeIsReady,
    required this.verify,
    required this.stopPlayback,
    required this.activate,
    required this.notifyLocked,
  });

  /// Reads everything from [context], a context above every profile session.
  factory RemoteSwitchEnv.fromContext(BuildContext context, {required BuildContext? Function() rootContext}) {
    final active = context.read<ActiveProfileProvider>();
    final connections = context.read<ConnectionRegistry>();
    final profileConnections = context.read<ProfileConnectionRegistry>();
    final binder = context.read<ActiveProfileBinder>();
    return RemoteSwitchEnv(
      profiles: active.profiles,
      activeId: active.activeId,
      activeIsReady: active.active != null && !active.isBinding && active.lastBindingSucceeded,
      verify: (profile, pin) => verifyRemoteProfilePin(
        profile: profile,
        pin: pin,
        listConnections: connections.list,
        persistTo: profileConnections,
        markPreVerified: binder.markPlexHomePreVerified,
      ),
      // Playback leaves first so its last progress report carries the
      // outgoing profile's token (as for a profile deep link).
      stopPlayback: () async {
        final coordinator = PlaybackCoordinator.instance;
        if (!await coordinator.stopVideoAndExit()) await coordinator.shutdownVideo();
      },
      activate: (profile, pin) async {
        final context = rootContext();
        if (context == null || !context.mounted) return false;
        return switchProfileFromUi(context, profile, pinVerified: true, verifiedPin: pin);
      },
      notifyLocked: () => showGlobalErrorSnackBar(t.companionRemote.profileSwitchLocked),
    );
  }

  final List<Profile> profiles;
  final String? activeId;

  /// The active profile is bound and usable (servers connected).
  final bool activeIsReady;
  final Future<RemoteSwitchStatus> Function(Profile profile, String? pin) verify;
  final Future<void> Function() stopPlayback;
  final Future<bool> Function(Profile profile, String? pin) activate;
  final void Function() notifyLocked;
}

/// A picker that a verified remote switch goes through, so it pops itself the
/// way it does after a tap. Returns whether the switch went through.
typedef RemotePickerSwitch = Future<bool> Function(Profile profile, String? pin);

/// Runs remote profile switches from the app root: they replace the profile
/// session (and the remote host inside it) they arrive through.
class RemoteProfileSwitcher {
  RemoteProfileSwitcher._();

  static final RemoteProfileSwitcher instance = RemoteProfileSwitcher._();

  /// A context above every profile session; installed by the app root.
  BuildContext? Function()? rootContext;

  RemoteSwitchGuard guard = RemoteSwitchGuard();

  @visibleForTesting
  RemoteSwitchEnv Function(BuildContext context)? debugEnv;

  /// Bounds how long one switch blocks the next; the switch itself goes on.
  static const switchTimeout = Duration(seconds: 45);

  Object? _pickerOwner;
  RemotePickerSwitch? _picker;
  bool _inFlight = false;

  /// Whether a "must choose" profile picker is on screen.
  bool get isPickerShowing => _picker != null;

  void attachPicker(Object owner, RemotePickerSwitch handler) {
    _pickerOwner = owner;
    _picker = handler;
  }

  void detachPicker(Object owner) {
    if (!identical(_pickerOwner, owner)) return;
    _pickerOwner = null;
    _picker = null;
  }

  @visibleForTesting
  void debugReset() {
    _pickerOwner = null;
    _picker = null;
    _inFlight = false;
    rootContext = null;
    debugEnv = null;
    guard = RemoteSwitchGuard();
  }

  /// The profile part of the host's `syncState`.
  Map<String, Object?> hostState(ActiveProfileProvider active) {
    final profile = active.active;
    return {
      'activeProfile': profile == null ? null : describeRemoteProfile(profile),
      'profileReady': profile != null && !isPickerShowing && !active.isBinding && active.lastBindingSucceeded,
      'pickerActive': isPickerShowing,
    };
  }

  /// Handles one `switchProfile` frame. [reply] sends `switchProfileResult`
  /// on the connection the frame came in on.
  Future<RemoteSwitchStatus> handle(
    Map<String, dynamic>? data, {
    required void Function(Map<String, dynamic> data) reply,
  }) async {
    var replied = false;
    RemoteSwitchStatus answer(RemoteSwitchStatus status, [Profile? profile]) {
      replied = true;
      reply({'status': status.name, if (profile != null) 'profile': describeRemoteProfile(profile)});
      return status;
    }

    final context = rootContext?.call();
    if (context == null || !context.mounted) return answer(RemoteSwitchStatus.failed);
    if (_inFlight) return answer(RemoteSwitchStatus.busy);
    final blocked = await guard.admit();
    if (blocked != null) return answer(blocked);
    if (!context.mounted) return answer(RemoteSwitchStatus.failed);

    final env = debugEnv?.call(context) ?? RemoteSwitchEnv.fromContext(context, rootContext: () => rootContext?.call());
    final target = resolveRemoteSwitchTarget(env.profiles, data ?? const {});
    final profile = target.profile;
    if (profile == null) return answer(target.error!);
    // On the picker the previous profile is still "active" but unbound, so
    // "already" also needs no picker on screen.
    if (env.activeId == profile.id && env.activeIsReady && !isPickerShowing) {
      return answer(RemoteSwitchStatus.already, profile);
    }

    final rawPin = data?['pin'];
    final pin = rawPin is String ? rawPin : (rawPin is int ? rawPin.toString() : null);

    _inFlight = true;
    try {
      appLogger.i('Remote profile switch: checking ${profile.displayName}');
      // Nothing changes before the PIN is known to be right: a wrong PIN
      // must not stop what the TV is playing.
      final verdict = await env.verify(profile, pin);
      if (verdict == RemoteSwitchStatus.wrongPin) {
        final locked = await guard.recordWrongPin();
        appLogger.w('Remote profile switch: wrong PIN for ${profile.displayName} (${guard.failures} so far)');
        if (locked) env.notifyLocked();
        return answer(locked ? RemoteSwitchStatus.lockedOut : RemoteSwitchStatus.wrongPin, profile);
      }
      if (verdict != RemoteSwitchStatus.verified) return answer(verdict, profile);
      if (remoteSwitchNeedsPin(profile)) await guard.recordPinAccepted();

      // Queued before the switch: closing the connection drains the queue.
      answer(RemoteSwitchStatus.verified, profile);

      final picker = _picker;
      final Future<bool> switching = picker != null
          ? picker(profile, pin)
          : () async {
              await env.stopPlayback();
              return env.activate(profile, pin);
            }();
      final switched = await switching.timeout(switchTimeout, onTimeout: () => false);
      appLogger.i('Remote profile switch: ${switched ? 'switched to' : 'did not switch to'} ${profile.displayName}');
      return switched ? RemoteSwitchStatus.verified : RemoteSwitchStatus.failed;
    } catch (e, stackTrace) {
      appLogger.e('Remote profile switch failed', error: e, stackTrace: stackTrace);
      return replied ? RemoteSwitchStatus.failed : answer(RemoteSwitchStatus.failed, profile);
    } finally {
      _inFlight = false;
    }
  }
}
