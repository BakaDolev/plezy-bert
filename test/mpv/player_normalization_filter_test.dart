import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_base.dart';

void main() {
  group('normalizationFilterFor', () {
    test('desktop keeps loudnorm', () {
      final filter = PlayerBase.normalizationFilterFor(isAndroid: false, isTvDevice: false);
      expect(filter, startsWith('loudnorm=I=-14:TP=-3:LRA=4'));
    });

    test('Android phones keep the 15 dB compressor chain', () {
      final filter = PlayerBase.normalizationFilterFor(isAndroid: true, isTvDevice: false);
      expect(filter, contains('makeup=15dB'));
      expect(filter, contains('alimiter=limit=-3dB'));
      expect(filter, isNot(contains('loudnorm')));
    });

    test('Android TV devices get 5 dB more makeup and the same limiter', () {
      final phone = PlayerBase.normalizationFilterFor(isAndroid: true, isTvDevice: false);
      final tv = PlayerBase.normalizationFilterFor(isAndroid: true, isTvDevice: true);
      expect(tv, contains('makeup=20dB'));
      expect(tv, contains('alimiter=limit=-3dB'));
      expect(tv.replaceFirst('makeup=20dB', 'makeup=15dB'), phone);
    });

    test('a TV flag outside Android changes nothing', () {
      expect(
        PlayerBase.normalizationFilterFor(isAndroid: false, isTvDevice: true),
        PlayerBase.normalizationFilterFor(isAndroid: false, isTvDevice: false),
      );
    });
  });
}
