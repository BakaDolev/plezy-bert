import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/fork_update/update_feed.dart';
import 'package:plezy/services/fork_update/update_flow.dart';
import 'package:plezy/services/fork_update/windows_updater.dart';

final _installer = Uint8List.fromList(utf8.encode('pretend this is the fork installer'));

class _FakeInstaller implements InstallerPlatform {
  _FakeInstaller(this.dir);
  final Directory dir;
  bool starts = true;
  final started = <String>[];
  int exits = 0;

  @override
  Future<String> updatesDir() async => dir.path;

  @override
  Future<bool> start(String path) async {
    started.add(path);
    return starts;
  }

  @override
  Future<void> exitForInstaller() async => exits++;
}

HttpSend _serve(List<int> bytes) =>
    (request) async => http.StreamedResponse(Stream.value(bytes), 200);

void main() {
  late Directory dir;
  late _FakeInstaller platform;
  late String publicKey;
  late String signature;
  late List<int> skipped;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fork-update');
    platform = _FakeInstaller(dir);
    skipped = [];
    final pair = await Ed25519().newKeyPair();
    publicKey = base64.encode((await pair.extractPublicKey()).bytes);
    signature = base64.encode((await Ed25519().sign(_installer, keyPair: pair)).bytes);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  AppcastItem item({String? sig, int? size, Uri? url}) => AppcastItem(
    build: 176,
    version: '2.23.0+176',
    notes: 'Fixed the thing.',
    installerUrl:
        url ??
        Uri.parse(
          'https://github.com/BakaDolev/plezy-bert/releases/download/2.23.0-176/PlezyFork-2.23.0-176-setup.exe',
        ),
    installerSize: size ?? _installer.length,
    edSignature: sig ?? signature,
  );

  WindowsUpdateFlow flow({AppcastItem? appcast, List<int>? served}) => WindowsUpdateFlow(
    item: appcast ?? item(),
    platform: platform,
    send: _serve(served ?? _installer),
    skipBuild: (build) async => skipped.add(build),
    publicKey: publicKey,
  );

  test('shows the version without the build suffix, and what installing does', () {
    final f = flow();
    expect(f.version, '2.23.0');
    expect(f.build, 176);
    expect(f.offerNote, contains('opens again'));
  });

  test('one Install downloads, checks the signature, starts the installer and closes Plezy', () async {
    final steps = <UpdateStep>[];
    final f = flow();
    f.addListener(() => steps.add(f.step));
    await f.install();
    expect(f.step, UpdateStep.handedOver);
    expect(steps, containsAllInOrder([UpdateStep.downloading, UpdateStep.checking, UpdateStep.handedOver]));
    expect(platform.started, [endsWith('PlezyFork-2.23.0-176-setup.exe')]);
    await Future<void>.delayed(Duration.zero);
    expect(platform.exits, 1);
  });

  test('a download that is not signed with the fork key never runs, and is deleted', () async {
    final other = await Ed25519().newKeyPair();
    final forged = base64.encode((await Ed25519().sign(_installer, keyPair: other)).bytes);
    for (final f in [
      flow(appcast: item(sig: forged)),
      flow(served: Uint8List.fromList(utf8.encode('pretend this is the fork installeR'))),
    ]) {
      await f.install();
      expect(f.step, UpdateStep.failed);
      expect(f.message, contains('signed'));
      expect(dir.listSync(), isEmpty);
    }
    expect(platform.started, isEmpty);
    expect(platform.exits, 0);
  });

  test('a wrong size fails before any check', () async {
    final f = flow(appcast: item(size: _installer.length + 5));
    await f.install();
    expect(f.step, UpdateStep.failed);
    expect(f.message, contains('incomplete'));
    expect(platform.started, isEmpty);
  });

  test("an installer that won't start keeps Plezy open", () async {
    platform.starts = false;
    final f = flow();
    await f.install();
    expect(f.step, UpdateStep.failed);
    expect(platform.exits, 0);
  });

  test('a release without an installer says so', () async {
    final f = flow(appcast: const AppcastItem(build: 176, version: '2.23.0+176'));
    await f.install();
    expect(f.step, UpdateStep.failed);
    expect(f.message, contains('no installer'));
  });

  test('Skip remembers this build', () async {
    await flow().skip();
    expect(skipped, [176]);
  });

  group('verifyUpdateSignature', () {
    test('only the fork key signature of these exact bytes passes', () async {
      expect(await verifyUpdateSignature(_installer, signature, publicKey: publicKey), isTrue);
      expect(await verifyUpdateSignature(_installer, signature), isFalse, reason: 'the real fork key did not sign it');
      expect(await verifyUpdateSignature(_installer, 'not base64!', publicKey: publicKey), isFalse);
      expect(await verifyUpdateSignature(_installer, base64.encode([1, 2, 3]), publicKey: publicKey), isFalse);
    });

    test('the built-in key is the one in the Windows runner', () {
      final rc = File('windows/runner/Runner.rc').readAsStringSync();
      expect(rc, contains(kForkUpdatePublicKey));
    });
  });
}
