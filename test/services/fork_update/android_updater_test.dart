import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/fork_update/android_updater.dart';
import 'package:plezy/services/fork_update/update_feed.dart';
import 'package:plezy/services/fork_update/update_flow.dart';

final _bytes = utf8.encode('pretend this is an APK');

ApkAsset _apk({String? sha, int? size, String name = 'PlezyFork-2.23.0-175-phone-arm64-v8a.apk'}) => ApkAsset(
  url: Uri.parse('https://github.com/BakaDolev/plezy-bert/releases/download/2.23.0-175/$name'),
  versionCode: 2175,
  sha256: sha ?? sha256.convert(_bytes).toString(),
  size: size ?? _bytes.length,
);

AndroidFeed _feed({ApkAsset? arm64, ApkAsset? v7a}) => AndroidFeed(
  build: 175,
  version: '2.23.0',
  notes: 'Fixed the thing.',
  apks: {'arm64-v8a': ?arm64, 'armeabi-v7a': ?v7a},
);

/// Answers every request with [bytes], in two chunks.
HttpSend _serve(List<int> bytes, {int status = 200, List<Uri>? log}) => (request) async {
  log?.add(request.url);
  final half = bytes.length ~/ 2;
  return http.StreamedResponse(Stream.fromIterable([bytes.sublist(0, half), bytes.sublist(half)]), status);
};

class _FakePlatform implements AppUpdatePlatform {
  _FakePlatform(this.dir);
  final Directory dir;
  bool sixtyFour = true;
  bool allowed = true;
  bool samsung = false;
  int free = 1 << 30;
  final installed = <String>[];
  int settingsOpened = 0;

  @override
  Future<bool> is64Bit() async => sixtyFour;
  @override
  Future<String> updatesDir() async => dir.path;
  @override
  Future<int> freeBytes() async => free;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<String?> openInstallSettings() async {
    settingsOpened++;
    return 'app';
  }

  @override
  Future<bool> installApk(String path) async {
    installed.add(path);
    return true;
  }

  @override
  Future<bool> isSamsung() async => samsung;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('updates'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('pickApk', () {
    test('a 64-bit process takes the arm64 build, a 32-bit one the v7a build', () {
      final arm64 = _apk();
      final v7a = _apk(name: 'PlezyFork-2.23.0-175-tv-armeabi-v7a.apk');
      expect(pickApk(_feed(arm64: arm64, v7a: v7a), is64Bit: true), same(arm64));
      expect(pickApk(_feed(arm64: arm64, v7a: v7a), is64Bit: false), same(v7a));
      expect(pickApk(_feed(arm64: arm64), is64Bit: false), isNull);
    });
  });

  group('downloadApk', () {
    test('keeps a file that matches its size and checksum', () async {
      final progress = <int>[];
      final file = await downloadApk(
        _apk(),
        dir: dir,
        send: _serve(_bytes),
        onProgress: (received, total) => progress.add(received),
      );
      expect(file.path, endsWith('PlezyFork-2.23.0-175-phone-arm64-v8a.apk'));
      expect(file.readAsBytesSync(), _bytes);
      expect(progress.last, _bytes.length);
      expect(dir.listSync().whereType<File>().map((f) => f.path.split(Platform.pathSeparator).last), [
        'PlezyFork-2.23.0-175-phone-arm64-v8a.apk',
      ]);
    });

    test('deletes a download that does not match, and says why', () async {
      for (final apk in [_apk(sha: List.filled(64, 'a').join()), _apk(size: _bytes.length + 1)]) {
        await expectLater(downloadApk(apk, dir: dir, send: _serve(_bytes)), throwsA(isA<UpdateDownloadException>()));
        expect(dir.listSync(), isEmpty, reason: 'nothing half-checked is left to install');
      }
    });

    test('stops a download bigger than the feed says', () async {
      final big = [..._bytes, ..._bytes];
      await expectLater(downloadApk(_apk(), dir: dir, send: _serve(big)), throwsA(isA<UpdateDownloadException>()));
      expect(dir.listSync(), isEmpty);
    });

    test('a server error is a failure', () async {
      await expectLater(
        downloadApk(_apk(), dir: dir, send: _serve(const [], status: 404)),
        throwsA(isA<UpdateDownloadException>()),
      );
    });

    test('a cancelled download leaves nothing behind', () async {
      await expectLater(
        downloadApk(_apk(), dir: dir, send: _serve(_bytes), isCancelled: () => true),
        throwsA(isA<UpdateDownloadCancelled>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('the file name comes from the URL, and nothing odd gets through', () {
      expect(apkFileName(_apk()), 'PlezyFork-2.23.0-175-phone-arm64-v8a.apk');
      expect(apkFileName(_apk(name: '..%2F..%2Fevil.apk')), 'update.apk');
      expect(apkFileName(_apk(name: 'not-an-apk.exe')), 'update.apk');
    });
  });

  group('AndroidUpdateFlow', () {
    late _FakePlatform platform;
    late List<int> skipped;

    AndroidUpdateFlow flow({AndroidFeed? feed, bool isTv = false}) => AndroidUpdateFlow(
      feed: feed ?? _feed(arm64: _apk()),
      platform: platform,
      send: _serve(_bytes),
      isTv: isTv,
      skipBuild: (build) async => skipped.add(build),
    );

    setUp(() {
      platform = _FakePlatform(dir);
      skipped = [];
    });

    test('Install downloads, checks and hands the APK to Android', () async {
      final f = flow();
      await f.install();
      expect(f.step, UpdateStep.handedOver);
      expect(platform.installed, [endsWith('PlezyFork-2.23.0-175-phone-arm64-v8a.apk')]);
    });

    test('without permission it explains, opens the settings, and tries again', () async {
      platform.allowed = false;
      final f = flow(isTv: true);
      await f.install();
      expect(f.step, UpdateStep.needsPermission);
      expect(f.message, contains('Unknown sources'));
      expect(platform.installed, isEmpty);

      await f.openSettings();
      expect(platform.settingsOpened, 1);

      platform.allowed = true;
      await f.install();
      expect(f.step, UpdateStep.handedOver);
    });

    test('too little free space stops before downloading', () async {
      platform.free = _bytes.length * 2;
      final f = flow();
      await f.install();
      expect(f.step, UpdateStep.failed);
      expect(f.message, contains('space'));
      expect(dir.listSync(), isEmpty);
    });

    test('a release without a build for this device says so', () async {
      platform.sixtyFour = false;
      final f = flow();
      await f.install();
      expect(f.step, UpdateStep.failed);
      expect(platform.installed, isEmpty);
    });

    test('a checksum mismatch never reaches the installer', () async {
      final f = flow(
        feed: _feed(arm64: _apk(sha: List.filled(64, 'b').join())),
      );
      await f.install();
      expect(f.step, UpdateStep.failed);
      expect(platform.installed, isEmpty);
    });

    test('Skip remembers this build', () async {
      await flow().skip();
      expect(skipped, [175]);
    });
  });

  test('purgeUpdates empties the folder', () async {
    File('${dir.path}/old.apk').writeAsStringSync('x');
    File('${dir.path}/old.apk.tmp').writeAsStringSync('x');
    await purgeUpdates(dir);
    expect(dir.listSync(), isEmpty);
  });
}
