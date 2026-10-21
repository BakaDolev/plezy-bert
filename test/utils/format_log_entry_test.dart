import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:plezy/utils/app_logger.dart';

/// The session log file is read by grepping for "Error:", so only warnings and
/// errors may carry that label. Info/debug lines pass ordinary data through the
/// logger's `error:` slot (e.g. `appLogger.i('Platform HTTP client', error: {...})`).
void main() {
  LogEntry entry(Level level, Object? error) =>
      LogEntry(timestamp: DateTime(2026, 10, 10, 12, 0, 0), level: level, message: 'marker', error: error);

  group('formatLogEntry extra-data label', () {
    test('an info line labels its extra data as details, not an error', () {
      final text = formatLogEntry(entry(Level.info, '{platform: windows}'));

      expect(text, contains('\nDetails: {platform: windows}'));
      expect(text, isNot(contains('Error:')));
    });

    test('a debug line labels its extra data as details, not an error', () {
      final text = formatLogEntry(entry(Level.debug, 'Raw API connection data'));

      expect(text, contains('\nDetails: Raw API connection data'));
      expect(text, isNot(contains('Error:')));
    });

    test('a warning keeps the Error label', () {
      final text = formatLogEntry(entry(Level.warning, 'SocketException: refused'));

      expect(text, contains('\nError: SocketException: refused'));
    });

    test('an error keeps the Error label', () {
      final text = formatLogEntry(entry(Level.error, 'DioException: 404'));

      expect(text, contains('\nError: DioException: 404'));
    });

    test('a line without extra data has no label', () {
      final text = formatLogEntry(entry(Level.info, null));

      expect(text, isNot(contains('Details:')));
      expect(text, isNot(contains('Error:')));
    });
  });

  group('formatLogVersion', () {
    test('shows the build number in brackets when there is one', () {
      expect(formatLogVersion('2.21.0', '168'), '2.21.0 (168)');
    });

    test('drops the brackets when the platform reports no build number (Windows)', () {
      expect(formatLogVersion('2.21.0', ''), '2.21.0');
    });
  });
}
