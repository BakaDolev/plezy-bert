import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/plex_home_switch.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/services/companion_remote/remote_profile_switch.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

class _MemoryStore implements RemoteSwitchGuardStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

PlexAccountConnection _account() => PlexAccountConnection(
  id: 'plex-1',
  accountToken: 'acct-token',
  clientIdentifier: 'cid-1',
  accountLabel: 'Test account',
  servers: const [],
  createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
);

Profile _plexHome({required String id, required String name, required String uuid, bool protected = false}) =>
    Profile.plexHome(
      id: id,
      displayName: name,
      parentConnectionId: 'plex-1',
      plexHomeUserUuid: uuid,
      plexProtected: protected,
      createdAt: DateTime(2026, 1, 1),
    );

Profile _local({required String id, required String name, String? pin}) => Profile.local(
  id: id,
  displayName: name,
  pinHash: pin == null ? null : computePinHash(pin),
  createdAt: DateTime(2026, 1, 1),
);

/// A fake plex.tv: `/switch` answers 201 for [correctPin] (or for no PIN when
/// [correctPin] is null) and 403 code 1041 otherwise, and counts requests.
class _FakePlex {
  _FakePlex({this.correctPin});

  final String? correctPin;
  int requests = 0;

  RemotePinMint get mint =>
      ({
        required PlexAccountConnection account,
        required String homeUserUuid,
        required bool requiresPin,
        required PlexHomeSwitchPinPrompt promptForPin,
        ProfileConnectionRegistry? persistTo,
        String? persistProfileId,
        String? logLabel,
      }) async {
        final client = MediaServerHttpClient(
          client: MockClient((request) async {
            requests++;
            final pin = request.url.queryParameters['pin'];
            if (pin == correctPin) {
              return http.Response(
                jsonEncode({'authToken': 'minted'}),
                201,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({
                'errors': [
                  {'code': 1041, 'message': 'Invalid PIN', 'status': 403},
                ],
              }),
              403,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.close);
        return switchPlexHomeUserWithPin(
          auth: PlexAuthService.forTesting(http: client),
          accountToken: account.accountToken,
          homeUserUuid: homeUserUuid,
          requiresPin: requiresPin,
          promptForPin: promptForPin,
        );
      };
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('RemoteSwitchGuard', () {
    test('locks after 3, 6 and 10 wrong PINs, longer each time', () async {
      var now = DateTime(2026, 11, 5, 12);
      final guard = RemoteSwitchGuard(store: _MemoryStore(), now: () => now);

      Future<bool> wrong() async {
        now = now.add(const Duration(seconds: 10));
        expect(await guard.admit(), isNull);
        return guard.recordWrongPin();
      }

      expect([await wrong(), await wrong(), await wrong()], [false, false, true]);
      expect(guard.lockedUntil, now.add(const Duration(minutes: 5)));
      now = now.add(const Duration(minutes: 4));
      expect(await guard.admit(), RemoteSwitchStatus.lockedOut);
      now = now.add(const Duration(minutes: 2));
      expect([await wrong(), await wrong(), await wrong()], [false, false, true]);
      expect(guard.lockedUntil, now.add(const Duration(hours: 1)));
      now = now.add(const Duration(hours: 2));
      expect([await wrong(), await wrong(), await wrong()], [false, false, true]);
      now = now.add(const Duration(hours: 2));
      expect(await wrong(), isTrue, reason: 'the 10th wrong PIN');
      expect(guard.lockedUntil, now.add(const Duration(hours: 24)));
    });

    test('survives a restart: the counts are persisted', () async {
      final store = _MemoryStore();
      var now = DateTime(2026, 11, 5, 12);
      final first = RemoteSwitchGuard(store: store, now: () => now);
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 10));
        await first.admit();
        await first.recordWrongPin();
      }
      final afterRestart = RemoteSwitchGuard(store: store, now: () => now);
      expect(await afterRestart.admit(), RemoteSwitchStatus.lockedOut);
      expect(afterRestart.failures, 3);
    });

    test('rate limits every attempt, PIN or not', () async {
      var now = DateTime(2026, 11, 5, 12);
      final guard = RemoteSwitchGuard(store: _MemoryStore(), now: () => now);
      expect(await guard.admit(), isNull);
      now = now.add(const Duration(seconds: 1));
      expect(await guard.admit(), RemoteSwitchStatus.rateLimited);
      now = now.add(RemoteSwitchGuard.minInterval);
      expect(await guard.admit(), isNull);
    });

    test('a correct PIN clears the count and the lock', () async {
      final now = DateTime(2026, 11, 5, 12);
      final guard = RemoteSwitchGuard(store: _MemoryStore(), now: () => now);
      await guard.recordWrongPin();
      await guard.recordWrongPin();
      await guard.recordPinAccepted();
      expect(guard.failures, 0);
      expect(await guard.recordWrongPin(), isFalse, reason: 'counting starts over');
    });
  });

  group('resolveRemoteSwitchTarget', () {
    final me = _plexHome(id: 'p-me', name: 'Alex', uuid: 'ABC123', protected: true);
    final robin = _plexHome(id: 'p-robin', name: 'Robin', uuid: 'def456');
    final kids = _local(id: 'l-kids', name: 'Kids');

    test('finds a profile by id, by Plex Home uuid (any case) or by name (any case)', () {
      expect(resolveRemoteSwitchTarget([me, robin, kids], {'profileId': 'l-kids'}).profile, kids);
      expect(resolveRemoteSwitchTarget([me, robin, kids], {'userUuid': 'abc123'}).profile, me);
      expect(resolveRemoteSwitchTarget([me, robin, kids], {'name': ' robin '}).profile, robin);
    });

    test('no match is noSuchProfile; no target at all too', () {
      expect(resolveRemoteSwitchTarget([me], {'name': 'Nobody'}).error, RemoteSwitchStatus.noSuchProfile);
      expect(resolveRemoteSwitchTarget([me], const {}).error, RemoteSwitchStatus.noSuchProfile);
    });

    test('two matches are ambiguous, never a guess', () {
      final twin = _plexHome(id: 'p-me-2', name: 'Alex', uuid: 'abc123');
      expect(resolveRemoteSwitchTarget([me, twin], {'userUuid': 'ABC123'}).error, RemoteSwitchStatus.ambiguous);
      expect(resolveRemoteSwitchTarget([me, twin], {'name': 'alex'}).error, RemoteSwitchStatus.ambiguous);
    });
  });

  group('verifyRemoteProfilePin', () {
    Future<(RemoteSwitchStatus, List<String>)> verify(Profile profile, String? pin, _FakePlex plex) async {
      final marked = <String>[];
      final status = await verifyRemoteProfilePin(
        profile: profile,
        pin: pin,
        listConnections: () async => [_account()],
        persistTo: null,
        markPreVerified: marked.add,
        mint: plex.mint,
      );
      return (status, marked);
    }

    test('a protected Plex Home profile with the right PIN is verified and marked pre-verified', () async {
      final plex = _FakePlex(correctPin: '1234');
      final (status, marked) = await verify(
        _plexHome(id: 'p-me', name: 'Me', uuid: 'u1', protected: true),
        '1234',
        plex,
      );
      expect(status, RemoteSwitchStatus.verified);
      expect(marked, ['p-me'], reason: 'so the binder reuses the token instead of its own PIN dialog');
      expect(plex.requests, 1);
    });

    test('a wrong PIN is wrongPin after exactly one try, and nothing is marked', () async {
      final plex = _FakePlex(correctPin: '1234');
      final (status, marked) = await verify(
        _plexHome(id: 'p-me', name: 'Me', uuid: 'u1', protected: true),
        '0000',
        plex,
      );
      expect(status, RemoteSwitchStatus.wrongPin);
      expect(marked, isEmpty);
      expect(plex.requests, 1, reason: 'no retry loop');
    });

    test('a protected profile with no PIN is wrongPin without asking Plex', () async {
      final plex = _FakePlex(correctPin: '1234');
      final (status, _) = await verify(_plexHome(id: 'p-me', name: 'Me', uuid: 'u1', protected: true), null, plex);
      expect(status, RemoteSwitchStatus.wrongPin);
      expect(plex.requests, 0);
    });

    test('an unprotected Plex Home profile still mints its token first (no binder dialog later)', () async {
      final plex = _FakePlex();
      final (status, marked) = await verify(_plexHome(id: 'p-robin', name: 'Robin', uuid: 'u2'), null, plex);
      expect(status, RemoteSwitchStatus.verified);
      expect(marked, ['p-robin']);
      expect(plex.requests, 1);
    });

    test('a profile cached as unprotected that Plex now protects takes the supplied PIN once', () async {
      final plex = _FakePlex(correctPin: '1234');
      final (status, _) = await verify(_plexHome(id: 'p-x', name: 'X', uuid: 'u3'), '1234', plex);
      expect(
        status,
        RemoteSwitchStatus.verified,
        reason: 'the second ask carries an error message; counting asks works',
      );
      expect(plex.requests, 2);
    });

    test('a local profile checks its PIN hash, with no network', () async {
      final plex = _FakePlex();
      expect((await verify(_local(id: 'l', name: 'Kids', pin: '4321'), '4321', plex)).$1, RemoteSwitchStatus.verified);
      expect((await verify(_local(id: 'l', name: 'Kids', pin: '4321'), '1111', plex)).$1, RemoteSwitchStatus.wrongPin);
      expect((await verify(_local(id: 'l', name: 'Kids'), null, plex)).$1, RemoteSwitchStatus.verified);
      expect(plex.requests, 0);
    });

    test('a Plex Home profile whose account is gone fails', () async {
      final status = await verifyRemoteProfilePin(
        profile: _plexHome(id: 'p-me', name: 'Me', uuid: 'u1', protected: true),
        pin: '1234',
        listConnections: () async => const [],
        persistTo: null,
        markPreVerified: (_) {},
        mint: _FakePlex(correctPin: '1234').mint,
      );
      expect(status, RemoteSwitchStatus.failed);
    });
  });

  group('RemoteProfileSwitcher.handle', () {
    final me = _plexHome(id: 'p-me', name: 'Alex', uuid: 'u-me', protected: true);
    final robin = _plexHome(id: 'p-robin', name: 'Robin', uuid: 'u-robin');
    late List<String> events;
    late DateTime now;

    Future<void> pumpRoot(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      );
      final switcher = RemoteProfileSwitcher.instance;
      switcher.debugReset();
      addTearDown(switcher.debugReset);
      now = DateTime(2026, 11, 5, 12);
      switcher.rootContext = () => captured;
      switcher.guard = RemoteSwitchGuard(store: _MemoryStore(), now: () => now);
      events = [];
    }

    void useEnv({String? activeId = 'p-robin', bool activeIsReady = true, bool activates = true}) {
      RemoteProfileSwitcher.instance.debugEnv = (_) => RemoteSwitchEnv(
        profiles: [me, robin],
        activeId: activeId,
        activeIsReady: activeIsReady,
        verify: (profile, pin) async {
          events.add('verify');
          if (!remoteSwitchNeedsPin(profile)) return RemoteSwitchStatus.verified;
          return pin == '2468' ? RemoteSwitchStatus.verified : RemoteSwitchStatus.wrongPin;
        },
        stopPlayback: () async => events.add('stopPlayback'),
        activate: (profile, pin) async {
          events.add('activate ${profile.id}');
          return activates;
        },
        notifyLocked: () => events.add('lockedNotice'),
      );
    }

    Future<RemoteSwitchStatus> send(Map<String, dynamic> data) {
      now = now.add(const Duration(seconds: 10));
      return RemoteProfileSwitcher.instance.handle(data, reply: (result) => events.add('reply ${result['status']}'));
    }

    testWidgets('a right PIN replies verified BEFORE playback stops and the switch starts', (tester) async {
      await pumpRoot(tester);
      useEnv();
      final status = await send({'name': 'Alex', 'pin': '2468'});
      expect(status, RemoteSwitchStatus.verified);
      expect(events, ['verify', 'reply verified', 'stopPlayback', 'activate p-me']);
    });

    testWidgets('a wrong PIN never stops playback or switches', (tester) async {
      await pumpRoot(tester);
      useEnv();
      final status = await send({'userUuid': 'u-me', 'pin': '0000'});
      expect(status, RemoteSwitchStatus.wrongPin);
      expect(events, ['verify', 'reply wrongPin']);
    });

    testWidgets('the third wrong PIN locks remote switching and says so on screen', (tester) async {
      await pumpRoot(tester);
      useEnv();
      await send({'name': 'Alex', 'pin': '0000'});
      await send({'name': 'Alex', 'pin': '0001'});
      final third = await send({'name': 'Alex', 'pin': '0002'});
      expect(third, RemoteSwitchStatus.lockedOut);
      expect(events.where((e) => e == 'lockedNotice'), hasLength(1));
      events.clear();
      final afterLock = await send({'name': 'Alex', 'pin': '2468'});
      expect(afterLock, RemoteSwitchStatus.lockedOut, reason: 'even the right PIN waits out the lock');
      expect(events, ['reply lockedOut'], reason: 'no PIN check while locked');
    });

    testWidgets('a PIN-free switch does not clear the wrong-PIN count', (tester) async {
      await pumpRoot(tester);
      useEnv(activeId: null);
      await send({'name': 'Alex', 'pin': '0000'});
      await send({'name': 'Alex', 'pin': '0001'});
      await send({'name': 'Robin'});
      expect(RemoteProfileSwitcher.instance.guard.failures, 2);
      expect(await send({'name': 'Alex', 'pin': '0002'}), RemoteSwitchStatus.lockedOut);
    });

    testWidgets('already on a ready profile is a no-op', (tester) async {
      await pumpRoot(tester);
      useEnv(activeId: 'p-me');
      expect(await send({'name': 'Alex', 'pin': '2468'}), RemoteSwitchStatus.already);
      expect(events, ['reply already']);
    });

    testWidgets('the same profile while it is not bound yet is switched, not "already"', (tester) async {
      await pumpRoot(tester);
      useEnv(activeId: 'p-me', activeIsReady: false);
      expect(await send({'name': 'Alex', 'pin': '2468'}), RemoteSwitchStatus.verified);
      expect(events, contains('activate p-me'));
    });

    testWidgets('with a picker on screen the switch goes through it, and "already" does not apply', (tester) async {
      await pumpRoot(tester);
      useEnv(activeId: 'p-me');
      final owner = Object();
      RemoteProfileSwitcher.instance.attachPicker(owner, (profile, pin) async {
        events.add('picker ${profile.id} pin=${pin == null ? 'none' : 'given'}');
        return true;
      });
      expect(await send({'name': 'Alex', 'pin': '2468'}), RemoteSwitchStatus.verified);
      expect(events, ['verify', 'reply verified', 'picker p-me pin=given']);
      RemoteProfileSwitcher.instance.detachPicker(owner);
      expect(RemoteProfileSwitcher.instance.isPickerShowing, isFalse);
    });

    testWidgets('a detach by a different owner leaves the picker attached', (tester) async {
      await pumpRoot(tester);
      final owner = Object();
      RemoteProfileSwitcher.instance.attachPicker(owner, (_, _) async => true);
      RemoteProfileSwitcher.instance.detachPicker(Object());
      expect(RemoteProfileSwitcher.instance.isPickerShowing, isTrue);
    });

    testWidgets('unknown targets are refused before any PIN check', (tester) async {
      await pumpRoot(tester);
      useEnv();
      expect(await send({'name': 'Nobody', 'pin': '2468'}), RemoteSwitchStatus.noSuchProfile);
      expect(events, ['reply noSuchProfile']);
    });

    testWidgets('a second switch while one runs is busy', (tester) async {
      await pumpRoot(tester);
      useEnv();
      final owner = Object();
      final gate = Completer<bool>();
      RemoteProfileSwitcher.instance.attachPicker(owner, (_, _) => gate.future);
      final first = send({'name': 'Robin'});
      await tester.pump();
      expect(await send({'name': 'Alex', 'pin': '2468'}), RemoteSwitchStatus.busy);
      gate.complete(true);
      expect(await first, RemoteSwitchStatus.verified);
    });

    testWidgets('a switch that does not go through comes back failed', (tester) async {
      await pumpRoot(tester);
      useEnv(activates: false);
      expect(await send({'name': 'Alex', 'pin': '2468'}), RemoteSwitchStatus.failed);
      expect(events, ['verify', 'reply verified', 'stopPlayback', 'activate p-me']);
    });
  });

  test('describeRemoteProfile never carries a PIN', () {
    final described = describeRemoteProfile(_local(id: 'l', name: 'Kids', pin: '4321'));
    expect(described, {'id': 'l', 'name': 'Kids'});
  });

  test('remoteSwitchNeedsPin follows the profile kind', () {
    expect(remoteSwitchNeedsPin(_plexHome(id: 'a', name: 'A', uuid: 'u', protected: true)), isTrue);
    expect(remoteSwitchNeedsPin(_plexHome(id: 'b', name: 'B', uuid: 'v')), isFalse);
    expect(remoteSwitchNeedsPin(_local(id: 'c', name: 'C', pin: '1')), isTrue);
    expect(remoteSwitchNeedsPin(_local(id: 'd', name: 'D')), isFalse);
  });
}
