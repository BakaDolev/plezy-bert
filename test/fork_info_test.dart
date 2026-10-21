import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/fork_info.dart';

void main() {
  group('formatForkDate', () {
    test('formats an ISO date as "Mon D, YYYY"', () {
      expect(formatForkDate('2026-08-20'), 'Aug 20, 2026');
      expect(formatForkDate('2026-01-05'), 'Jan 5, 2026');
      expect(formatForkDate('2026-12-31'), 'Dec 31, 2026');
    });

    test('returns the input unchanged when it is not a valid ISO date', () {
      expect(formatForkDate('not-a-date'), 'not-a-date');
      expect(formatForkDate('2026-13-01'), '2026-13-01'); // month out of range
      expect(formatForkDate('2026-08'), '2026-08');
    });
  });

  test('forkMarkerLabel reads "<name> · updated <date>"', () {
    expect(forkMarkerLabel(), '$kForkName · updated ${formatForkDate(kForkUpdated)}');
  });

  group('forkBuildFooter', () {
    test('names the upstream base', () {
      expect(forkBuildFooter(), contains('on Plezy $kForkUpstreamBase'));
    });

    test('drops the build id when GIT_COMMIT is undefined (as in tests)', () {
      // No --dart-define in `flutter test`, so kForkGitCommit is empty.
      expect(forkBuildFooter(), 'on Plezy $kForkUpstreamBase');
    });
  });
}
