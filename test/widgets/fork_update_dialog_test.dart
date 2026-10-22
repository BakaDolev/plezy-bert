import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/fork_update/android_updater.dart';
import 'package:plezy/services/fork_update/update_feed.dart';
import 'package:plezy/services/fork_update/windows_updater.dart';
import 'package:plezy/widgets/fork_update_dialog.dart';

import '../test_helpers/theme.dart';

final _bytes = utf8.encode('pretend this is an APK');

class _FakePlatform implements AppUpdatePlatform {
  _FakePlatform(this.dir);
  final Directory dir;
  bool allowed = true;
  final installed = <String>[];

  @override
  Future<bool> is64Bit() async => true;
  @override
  Future<String> updatesDir() async => dir.path;
  @override
  Future<int> freeBytes() async => 1 << 30;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<String?> openInstallSettings() async => 'app';
  @override
  Future<bool> installApk(String path) async {
    installed.add(path);
    return true;
  }

  @override
  Future<bool> isSamsung() async => false;
}

void main() {
  late Directory dir;
  late _FakePlatform platform;
  late List<int> skipped;
  late AndroidUpdateFlow flow;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('updates');
    platform = _FakePlatform(dir);
    skipped = [];
    flow = AndroidUpdateFlow(
      feed: AndroidFeed(
        build: 175,
        version: '0.0.2',
        notes: 'Fixed the thing.',
        apks: {
          'arm64-v8a': ApkAsset(
            url: Uri.parse('https://github.com/BakaDolev/plezy-bert/releases/download/v0.0.2/x-phone-arm64-v8a.apk'),
            versionCode: 2175,
            sha256: sha256.convert(_bytes).toString(),
            size: _bytes.length,
          ),
        },
      ),
      platform: platform,
      send: (request) async => http.StreamedResponse(Stream.value(_bytes), 200),
      isTv: true,
      skipBuild: (build) async => skipped.add(build),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, {bool isSamsung = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showForkUpdateDialog(context, flow, isSamsung: isSamsung),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The button holding the primary focus (what a TV remote's OK presses).
  void expectFocusOn(WidgetTester tester, String label, {required List<String> notOn}) {
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    final subtree = find.byWidget(focused!.widget);
    expect(find.descendant(of: subtree, matching: find.text(label)), findsOneWidget);
    for (final other in notOn) {
      expect(find.descendant(of: subtree, matching: find.text(other)), findsNothing);
    }
  }

  testWidgets('offers the build with its notes, Install in focus', (tester) async {
    await open(tester, isSamsung: true);
    expect(find.text('Plezy Fork 0.0.2 (beta) is ready to install.'), findsOneWidget);
    expect(find.text('Fixed the thing.'), findsOneWidget);
    expect(find.textContaining('Auto Blocker'), findsOneWidget);
    expectFocusOn(tester, 'Install', notOn: ['Later', 'Skip this version']);
  });

  testWidgets('without permission, Open settings takes the focus', (tester) async {
    platform.allowed = false;
    await open(tester);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unknown sources'), findsOneWidget);
    expectFocusOn(tester, 'Open settings', notOn: ['Later', 'Install']);
  });

  testWidgets('a failed download offers Try again, in focus', (tester) async {
    flow = AndroidUpdateFlow(
      feed: flow.feed,
      platform: platform,
      send: (request) async => http.StreamedResponse(Stream.value(utf8.encode('something else')), 200),
      isTv: true,
      skipBuild: flow.skipBuild,
    );
    await open(tester);
    await tester.runAsync(flow.install);
    await tester.pumpAndSettle();
    expect(find.textContaining("doesn't match"), findsNothing, reason: 'a wrong size is caught first');
    expect(find.textContaining('could not be downloaded'), findsOneWidget);
    expectFocusOn(tester, 'Try again', notOn: ['Close']);
    expect(platform.installed, isEmpty);
  });

  testWidgets('Skip this version remembers the build and closes', (tester) async {
    await open(tester);
    await tester.tap(find.text('Skip this version'));
    await tester.pumpAndSettle();
    expect(skipped, [175]);
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('closes once Android\'s installer has the update', (tester) async {
    await open(tester);
    await tester.runAsync(flow.install);
    await tester.pumpAndSettle();
    expect(platform.installed, hasLength(1));
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('on Windows: says Plezy reopens, then one Install takes it to the installer', (tester) async {
    final pair = await tester.runAsync(() => Ed25519().newKeyPair());
    final key = base64.encode((await tester.runAsync(pair!.extractPublicKey))!.bytes);
    final sig = base64.encode((await tester.runAsync(() => Ed25519().sign(_bytes, keyPair: pair)))!.bytes);
    final installer = _FakeInstaller(dir);
    final windows = WindowsUpdateFlow(
      item: AppcastItem(
        build: 176,
        version: '1.1.0',
        notes: 'Fixed the thing.',
        installerUrl: Uri.parse('https://github.com/BakaDolev/plezy-bert/releases/download/v1.1.0/x-setup.exe'),
        installerSize: _bytes.length,
        edSignature: sig,
      ),
      platform: installer,
      send: (request) async => http.StreamedResponse(Stream.value(_bytes), 200),
      skipBuild: (build) async => skipped.add(build),
      publicKey: key,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showForkUpdateDialog(context, windows, isSamsung: false),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Plezy Fork 1.1.0 is ready to install.'), findsOneWidget);
    expect(find.textContaining('opens again by itself'), findsOneWidget);
    expectFocusOn(tester, 'Install', notOn: ['Later', 'Skip this version']);

    await tester.runAsync(windows.install);
    await tester.pumpAndSettle();
    expect(installer.started, hasLength(1), reason: '${windows.step}: ${windows.message}');
    expect(find.text('Update available'), findsNothing);
  });
}

class _FakeInstaller implements InstallerPlatform {
  _FakeInstaller(this.dir);
  final Directory dir;
  final started = <String>[];

  @override
  Future<String> updatesDir() async => dir.path;
  @override
  Future<bool> start(String path) async {
    started.add(path);
    return true;
  }

  @override
  Future<void> exitForInstaller() async {}
}
