import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/file_log_sink.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('plezy_file_log_sink_test');
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      try {
        tempRoot.deleteSync(recursive: true);
      } catch (_) {
        // Windows can hold a handle briefly; a leaked temp dir must not fail a test.
      }
    }
  });

  File sessionFile(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

  group('pre-init buffering', () {
    test('replays lines written before start(), in order', () async {
      final sink = FileLogSink();
      sink.writeLine('before one');
      sink.writeLine('before two');

      await sink.start(tempRoot, fileName: 'plezy-session.log');
      await sink.close();

      final contents = sessionFile(tempRoot, 'plezy-session.log').readAsStringSync();
      expect(contents.indexOf('before one'), lessThan(contents.indexOf('before two')));
    });

    test('drops the oldest buffered lines past the cap rather than growing without bound', () async {
      final sink = FileLogSink(maxBufferedLines: 3);
      for (var i = 0; i < 10; i++) {
        sink.writeLine('line $i');
      }

      await sink.start(tempRoot, fileName: 'plezy-session.log');
      await sink.close();

      final contents = sessionFile(tempRoot, 'plezy-session.log').readAsStringSync();
      // Oldest dropped, newest kept — the tail is what explains a startup failure.
      expect(contents, isNot(contains('line 0')));
      expect(contents, contains('line 9'));
      expect(contents, contains('dropped'));
    });

    test('applies lateRedact to buffered lines only', () async {
      // Buffered lines predate token registration, so they are re-redacted at
      // flush; live lines were already redacted by the printer.
      final sink = FileLogSink();
      sink.writeLine('early secret=abc123');

      await sink.start(
        tempRoot,
        fileName: 'plezy-session.log',
        lateRedact: (line) => line.replaceAll('abc123', '[REDACTED]'),
      );
      sink.writeLine('live secret=abc123');
      await sink.close();

      final contents = sessionFile(tempRoot, 'plezy-session.log').readAsStringSync();
      expect(contents, contains('early secret=[REDACTED]'));
      expect(contents, contains('live secret=abc123'));
    });
  });

  group('writing', () {
    test('a line is on disk as soon as writeLine returns', () async {
      // The whole point of synchronous writes: a hard kill must not lose the tail.
      final sink = FileLogSink();
      await sink.start(tempRoot, fileName: 'plezy-session.log');

      sink.writeLine('durable line');

      final file = sessionFile(tempRoot, 'plezy-session.log');
      expect(file.readAsStringSync(), contains('durable line'));
      // The reported LENGTH must be live too, not just the content: Windows
      // leaves the directory entry at 0 for an open handle unless it is
      // flushed, which makes the file look empty in Explorer all session.
      expect(file.lengthSync(), greaterThan(0));
      await sink.close();
    });

    test('writes the header first when one is given', () async {
      final sink = FileLogSink();
      await sink.start(tempRoot, fileName: 'plezy-session.log', header: 'HEADER LINE');
      sink.writeLine('after');
      await sink.close();

      final contents = sessionFile(tempRoot, 'plezy-session.log').readAsStringSync();
      expect(contents.indexOf('HEADER LINE'), lessThan(contents.indexOf('after')));
    });
  });

  group('rotation', () {
    test('prunes to the newest N session files at start', () async {
      for (var i = 0; i < 6; i++) {
        final f = sessionFile(tempRoot, 'plezy-old-$i.log')..writeAsStringSync('old $i');
        // Distinct mtimes so "newest" is well defined.
        f.setLastModifiedSync(DateTime(2026, 1, 1 + i));
      }
      // An unrelated file must survive pruning.
      sessionFile(tempRoot, 'notes.txt').writeAsStringSync('keep me');

      final sink = FileLogSink(maxSessionFiles: 3);
      await sink.start(tempRoot, fileName: 'plezy-new.log');
      await sink.close();

      final names = tempRoot.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, contains('notes.txt'));
      expect(names, contains('plezy-new.log'));
      // 3 kept total including the new one, so the two newest old files survive.
      expect(names, contains('plezy-old-5.log'));
      expect(names, contains('plezy-old-4.log'));
      expect(names, isNot(contains('plezy-old-0.log')));
      expect(names, isNot(contains('plezy-old-1.log')));
    });

    test('rolls to a .1 file at the byte cap and keeps writing', () async {
      final sink = FileLogSink(maxBytesPerFile: 200);
      await sink.start(tempRoot, fileName: 'plezy-session.log');

      for (var i = 0; i < 40; i++) {
        sink.writeLine('padding line $i ${'x' * 20}');
      }
      sink.writeLine('MOST RECENT');
      await sink.close();

      final live = sessionFile(tempRoot, 'plezy-session.log');
      final rolled = sessionFile(tempRoot, 'plezy-session.1.log');

      expect(rolled.existsSync(), isTrue, reason: 'cap should have rolled the file');
      // The most recent output must always be in the live file, never the
      // rollover — rolling after the write instead of before would put it there.
      expect(live.readAsStringSync(), contains('MOST RECENT'));
      expect(rolled.readAsStringSync(), isNot(contains('MOST RECENT')));
      // Old content really left the live file, so the cap is doing something.
      expect(live.readAsStringSync(), isNot(contains('padding line 0')));
      expect(rolled.lengthSync(), greaterThan(0));
      expect(live.lengthSync(), lessThanOrEqualTo(200 * 2));
    });
  });

  group('failure is never fatal', () {
    test('start() on an unusable directory degrades to inactive without throwing', () async {
      // A path whose parent is a file cannot be created as a directory.
      final blocker = sessionFile(tempRoot, 'blocker')..writeAsStringSync('x');
      final impossible = Directory('${blocker.path}${Platform.pathSeparator}nested');

      final sink = FileLogSink();
      await sink.start(impossible, fileName: 'plezy-session.log');

      expect(sink.isActive, isFalse);
      // Still must not throw once inactive.
      sink.writeLine('goes nowhere');
      await sink.close();
    });

    test('writeLine before start never throws', () {
      final sink = FileLogSink();
      expect(() => sink.writeLine('no destination yet'), returnsNormally);
      expect(sink.isActive, isFalse);
    });
  });
}
