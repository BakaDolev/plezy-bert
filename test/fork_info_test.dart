import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/fork_info.dart';

void main() {
  test('forkMarkerLabel reads "<name> · based on Plezy <upstream>"', () {
    expect(forkMarkerLabel(), '$kForkName · based on Plezy $kForkUpstreamBase');
  });

  group('forkVersionLabel', () {
    test('a version whose last number is above 0 is a beta', () {
      expect(forkVersionLabel('0.0.1'), '0.0.1 (beta)');
      expect(forkVersionLabel('1.1.3'), '1.1.3 (beta)');
    });

    test('a release (last number 0) has no label', () {
      expect(forkVersionLabel('1.0.0'), '1.0.0');
      expect(forkVersionLabel('2.4.0'), '2.4.0');
    });

    test('anything that is not x.y.z is shown as it is', () {
      expect(forkVersionLabel(' 2.23.0+179 '), '2.23.0+179');
      expect(forkVersionLabel(''), '');
    });
  });

  group('forkBuildFooter', () {
    test('names the upstream base and never the commit', () {
      expect(forkBuildFooter(version: '0.0.2'), 'Plezy Fork 0.0.2 (beta) · on Plezy $kForkUpstreamBase');
      expect(forkBuildFooter(version: '1.0.0'), 'Plezy Fork 1.0.0 · on Plezy $kForkUpstreamBase');
    });

    test('a local build without a version names only the upstream base (as in tests)', () {
      // No --dart-define in `flutter test`, so kForkVersion is empty.
      expect(forkBuildFooter(), 'on Plezy $kForkUpstreamBase');
    });
  });
}
