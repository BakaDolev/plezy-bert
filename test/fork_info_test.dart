import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/fork_info.dart';

void main() {
  test('forkMarkerLabel reads "<name> · based on Plezy <upstream>"', () {
    expect(forkMarkerLabel(), '$kForkName · based on Plezy $kForkUpstreamBase');
  });

  group('forkVersionLabel', () {
    test('every version is a plain release: a last number above 0 is a bug-fix release (2026-11-05)', () {
      expect(forkVersionLabel('2.0.1'), '2.0.1');
      expect(forkVersionLabel('1.0.0'), '1.0.0');
      expect(forkVersionLabel('2.4.0'), '2.4.0');
    });

    test('only a build made as a beta says so', () {
      expect(forkVersionLabel('0.0.1', beta: true), '0.0.1 (beta)');
      expect(forkVersionLabel('2.0.0', beta: true), '2.0.0 (beta)');
      expect(forkVersionLabel('dev', beta: true), 'dev');
    });

    test('anything that is not x.y.z is shown as it is', () {
      expect(forkVersionLabel(' 2.23.0+179 '), '2.23.0+179');
      expect(forkVersionLabel(''), '');
    });
  });

  group('forkBuildFooter', () {
    test('names the upstream base and never the commit', () {
      expect(forkBuildFooter(version: '2.0.1'), 'Plezy Fork 2.0.1 · on Plezy $kForkUpstreamBase');
      expect(forkBuildFooter(version: '0.0.2', beta: true), 'Plezy Fork 0.0.2 (beta) · on Plezy $kForkUpstreamBase');
    });

    test('a local build without a version names only the upstream base (as in tests)', () {
      // No --dart-define in `flutter test`, so kForkVersion is empty.
      expect(forkBuildFooter(), 'on Plezy $kForkUpstreamBase');
    });
  });
}
