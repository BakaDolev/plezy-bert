import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/newer_progress_guard.dart';

Duration _m(int minutes, [int seconds = 0]) => Duration(minutes: minutes, seconds: seconds);

void main() {
  late Duration? server;
  late int reads;
  late NewerProgressGuard guard;

  setUp(() {
    server = null;
    reads = 0;
    guard = NewerProgressGuard(
      readResumePoint: () async {
        reads++;
        return server;
      },
    );
  });

  test('nothing is read before this device has reported anything', () async {
    expect(await guard.mayReportPaused(), isTrue);
    expect(reads, 0);
  });

  test('another device moving past this paused one holds its reports', () async {
    guard.noteReported(_m(28, 31));
    server = _m(28, 31);
    expect(await guard.mayReportPaused(), isTrue); // the first look only remembers

    server = _m(33); // the phone played on
    expect(await guard.mayReportPaused(), isFalse);
    expect(guard.overtakenAt.value, _m(33));

    server = _m(45, 3); // and on: the held device keeps the newest spot
    expect(await guard.mayReportPaused(), isFalse);
    expect(guard.overtakenAt.value, _m(45, 3));
  });

  test('the server catching up on this device\'s own report is not another device', () async {
    guard.noteReported(_m(10));
    server = _m(9, 50); // not saved yet
    expect(await guard.mayReportPaused(), isTrue);
    guard.noteReported(_m(28, 31));
    server = _m(28, 31);
    expect(await guard.mayReportPaused(), isTrue);
    expect(guard.overtakenAt.value, isNull);
  });

  test('an old resume point the server kept is not another device', () async {
    // Started from the beginning of an item Plex had at 30:00; a short watch
    // does not replace that resume point.
    guard.noteReported(const Duration(seconds: 40));
    server = _m(30);
    expect(await guard.mayReportPaused(), isTrue);
    expect(await guard.mayReportPaused(), isTrue);
    expect(guard.overtakenAt.value, isNull);
  });

  test('seeking back on this device is not another device', () async {
    guard.noteReported(_m(40));
    server = _m(40);
    expect(await guard.mayReportPaused(), isTrue);
    guard.noteReported(_m(20)); // scrubbed back while paused
    server = _m(20);
    expect(await guard.mayReportPaused(), isTrue);
    expect(guard.overtakenAt.value, isNull);
  });

  test('a few seconds of drift is not another device', () async {
    guard.noteReported(_m(28, 31));
    server = _m(28, 31);
    await guard.mayReportPaused();
    server = _m(28, 34);
    expect(await guard.mayReportPaused(), isTrue);
  });

  test('a failed read reports as usual', () async {
    final failing = NewerProgressGuard(readResumePoint: () async => throw Exception('offline'));
    failing.noteReported(_m(5));
    expect(await failing.mayReportPaused(), isTrue);
    expect(await failing.mayReportPaused(), isTrue);
  });

  test('the closing report lands on the newest spot once overtaken, and on its own spot otherwise', () async {
    guard.noteReported(_m(28, 31));
    server = _m(28, 31);
    expect(await guard.closingSpot(), isNull);
    await guard.mayReportPaused();
    server = _m(40);
    await guard.mayReportPaused();
    server = _m(45, 3);
    expect(await guard.closingSpot(), _m(45, 3));

    server = null; // finished elsewhere, or the read failed: the last spot seen still holds
    expect(await guard.closingSpot(), _m(45, 3));
  });

  test('once released, this device reports again', () async {
    guard.noteReported(_m(28, 31));
    server = _m(28, 31);
    await guard.mayReportPaused();
    server = _m(40);
    await guard.mayReportPaused();
    guard.release();
    expect(guard.overtakenAt.value, isNull);

    guard.noteReported(_m(40, 10)); // continued from the newer spot
    server = _m(40, 10);
    expect(await guard.mayReportPaused(), isTrue);
  });

  test('a session closed at its own spot learns whether another device went further meanwhile', () async {
    server = _m(28, 31);
    expect(await guard.recheckAfterClose(_m(28, 31)), isFalse);

    final restored = NewerProgressGuard(readResumePoint: () async => _m(45, 3));
    expect(await restored.recheckAfterClose(_m(28, 31)), isTrue);
    expect(restored.overtakenAt.value, _m(45, 3));
  });
}
