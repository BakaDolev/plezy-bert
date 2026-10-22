import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/fork_update/fork_update_check.dart';
import 'package:plezy/services/fork_update/fork_updater.dart';

final _feed = Uri.parse('https://github.com/BakaDolev/plezy-bert/releases/latest/download/appcast.xml');

void main() {
  group('runForkUpdateCheck', () {
    Future<ForkUpdateOutcome> run({
      required ForkUpdateCheck check,
      bool playingBefore = false,
      bool playingAfter = false,
      List<String>? calls,
    }) {
      var looked = false;
      return runForkUpdateCheck(
        isPlaybackActive: () => looked ? playingAfter : playingBefore,
        look: () async {
          looked = true;
          calls?.add('look');
          return check;
        },
        show: (check) async {
          calls?.add('show ${check.build}');
          return ForkUpdateOutcome.shown;
        },
      );
    }

    test('an available build is shown', () async {
      final calls = <String>[];
      final outcome = await run(
        check: ForkUpdateCheck(ForkUpdateStatus.available, feedUri: _feed, build: 175),
        calls: calls,
      );
      expect(outcome, ForkUpdateOutcome.shown);
      expect(calls, ['look', 'show 175']);
    });

    test('nothing is looked up while something plays', () async {
      final calls = <String>[];
      final outcome = await run(
        check: ForkUpdateCheck(ForkUpdateStatus.available, feedUri: _feed, build: 175),
        playingBefore: true,
        calls: calls,
      );
      expect(outcome, ForkUpdateOutcome.playing);
      expect(calls, isEmpty);
    });

    test('playback started while looking still wins', () async {
      final calls = <String>[];
      final outcome = await run(
        check: ForkUpdateCheck(ForkUpdateStatus.available, feedUri: _feed, build: 175),
        playingAfter: true,
        calls: calls,
      );
      expect(outcome, ForkUpdateOutcome.playing);
      expect(calls, ['look']);
    });

    test('every other answer is reported, never shown', () async {
      final expected = {
        ForkUpdateStatus.upToDate: ForkUpdateOutcome.upToDate,
        ForkUpdateStatus.skipped: ForkUpdateOutcome.upToDate,
        ForkUpdateStatus.noRelease: ForkUpdateOutcome.noRelease,
        ForkUpdateStatus.failed: ForkUpdateOutcome.failed,
      };
      for (final MapEntry(key: status, value: outcome) in expected.entries) {
        final calls = <String>[];
        expect(
          await run(check: ForkUpdateCheck(status), calls: calls),
          outcome,
          reason: '$status',
        );
        expect(calls, ['look']);
      }
    });
  });

  group('updateChecksOff', () {
    test("reads the installer's file in this user's local app data", () {
      final looked = <String>[];
      final off = updateChecksOff(
        environment: {'LOCALAPPDATA': r'C:\Users\example\AppData\Local'},
        exists: (path) {
          looked.add(path);
          return true;
        },
      );
      expect(off, isTrue);
      expect(looked, [r'C:\Users\example\AppData\Local\Plezy Fork\update-checks-off']);
    });

    test('checks stay on without the file', () {
      expect(updateChecksOff(environment: {'LOCALAPPDATA': r'C:\x'}, exists: (_) => false), isFalse);
    });

    test('checks stay on when there is no local app data folder', () {
      var looked = false;
      bool exists(String _) => looked = true;
      expect(updateChecksOff(environment: const {}, exists: exists), isFalse);
      expect(updateChecksOff(environment: const {'LOCALAPPDATA': ''}, exists: exists), isFalse);
      expect(looked, isFalse);
    });
  });
}
