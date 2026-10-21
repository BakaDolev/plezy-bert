import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/file_log_sink.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

/// Covers the wiring between `appLogger` and the session log file — the part
/// the FileLogSink unit tests deliberately do not know about.
///
/// `flutter test` gives each test file its own isolate, so the FileLogSink
/// singleton and the logger globals are fresh here.
void main() {
  late Directory tempRoot;
  late File logFile;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('plezy_app_logger_file_test');
    await FileLogSink.instance.start(tempRoot, fileName: 'plezy-test.log', lateRedact: redactLogText);
    logFile = File('${tempRoot.path}${Platform.pathSeparator}plezy-test.log');
  });

  tearDownAll(() async {
    await FileLogSink.instance.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {
      // A leaked temp dir must not fail the suite on Windows.
    }
  });

  test('a debug line reaches the file (the file always captures debug)', () {
    // The stock app drops every appLogger.d line unless the debug setting is on
    // (it defaults off). A session log that loses them is not worth writing, so
    // the file records every event regardless of the display level — this
    // asserts that, not just the plumbing. (See the display-level test below.)
    appLogger.d('marker-debug-line');

    expect(logFile.readAsStringSync(), contains('marker-debug-line'));
  });

  test('the formatted line carries a timestamp and the level', () {
    appLogger.w('marker-warning-line');

    final contents = logFile.readAsStringSync();
    expect(contents, contains('[WARNING] marker-warning-line'));
    // SimplePrinter emits neither a timestamp nor a stack trace, which is why
    // the file is formatted from LogEntry instead of from the printer's output.
    expect(contents, matches(RegExp(r'\[\d{2}:\d{2}:\d{2}\.\d{3}\] \[WARNING\] marker-warning-line')));
  });

  test('a registered token is redacted before it reaches the file', () {
    LogRedactionManager.registerToken('supersecrettokenvalue');

    appLogger.i('connecting with token supersecrettokenvalue');

    final contents = logFile.readAsStringSync();
    expect(contents, isNot(contains('supersecrettokenvalue')));
    expect(contents, contains('connecting with token'));
  });

  test('a stack trace reaches the file redacted, not raw', () {
    // Stack traces used to bypass redaction entirely; on disk that would be
    // permanent. The trace text here carries a registered token.
    LogRedactionManager.registerToken('tracetokenvalue');

    appLogger.e(
      'failure with trace',
      error: 'boom',
      stackTrace: StackTrace.fromString('#0 fn (file:///app.dart?token=tracetokenvalue:1:1)'),
    );

    final contents = logFile.readAsStringSync();
    expect(contents, contains('Stack trace:'));
    expect(contents, isNot(contains('tracetokenvalue')));
  });

  test('the file keeps debug lines even when the display level drops to info', () {
    // setLoggerLevel(false) lowers the in-app viewer + console to info, but the
    // session log FILE must still capture debug — that is the point of file
    // logging. Regression guard: an earlier version pinned the whole pipeline to
    // debug, which pushed debug request-logs into MemoryLogOutput and broke
    // upstream's failover-diagnostics redaction test.
    setLoggerLevel(false);
    addTearDown(() => setLoggerLevel(true));

    appLogger.d('marker-debug-at-info-display');

    // File still has it...
    expect(logFile.readAsStringSync(), contains('marker-debug-at-info-display'));
    // ...but the in-app viewer buffer does not, because the display level is info.
    expect(
      MemoryLogOutput.getLogs().map((e) => e.message),
      isNot(contains('marker-debug-at-info-display')),
    );
  });
}
