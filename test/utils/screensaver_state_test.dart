import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/device_channel.dart';
import 'package:plezy/utils/screensaver_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Future<Object?>? Function(MethodCall call)? handler) =>
      messenger.setMockMethodCallHandler(deviceChannel, handler);

  tearDown(() => answer(null));

  test('reports a showing screensaver', () async {
    final asked = <String>[];
    answer((call) async {
      asked.add(call.method);
      return true;
    });

    expect(await isScreensaverShowing(), isTrue);
    expect(asked, ['isScreensaverShowing']);
  });

  test('reports no screensaver when the native side says so', () async {
    answer((call) async => false);

    expect(await isScreensaverShowing(), isFalse);
  });

  test('treats an unanswered query as no screensaver', () async {
    answer((call) async => null);
    expect(await isScreensaverShowing(), isFalse, reason: 'null reply');

    answer(null);
    expect(await isScreensaverShowing(), isFalse, reason: 'no native handler (non-Android, older build)');

    answer((call) async => throw PlatformException(code: 'boom'));
    expect(await isScreensaverShowing(), isFalse, reason: 'native error');
  });
}
