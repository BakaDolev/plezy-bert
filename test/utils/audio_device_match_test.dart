import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/utils/audio_device_match.dart';

const _devices = [
  AudioDevice(name: 'auto', description: 'Autoselect device'),
  AudioDevice(name: 'wasapi/{0.0.0.111}', description: 'Speakers (Realtek(R) Audio)'),
  AudioDevice(name: 'wasapi/{0.0.0.222}', description: 'LG TV (NVIDIA High Definition Audio)'),
  AudioDevice(name: 'wasapi/{0.0.0.333}', description: 'Headphones (Arctis 7)'),
];

void main() {
  group('matchAudioDevice', () {
    test('matches the human-readable description, which is what a person says', () {
      expect(matchAudioDevice('tv', _devices), _devices[2]);
      expect(matchAudioDevice('headphones', _devices), _devices[3]);
      expect(matchAudioDevice('speakers', _devices), _devices[1]);
    });

    test('matches multi-word and mixed-case queries', () {
      expect(matchAudioDevice('LG TV', _devices), _devices[2]);
      expect(matchAudioDevice('  ArCtIs  ', _devices), _devices[3]);
    });

    test('matches the raw device name too, so an exact id always works', () {
      expect(matchAudioDevice('wasapi/{0.0.0.222}', _devices), _devices[2]);
      expect(matchAudioDevice('auto', _devices), _devices[0]);
    });

    test('returns the first match so repeated calls are stable', () {
      const ambiguous = [
        AudioDevice(name: 'a', description: 'Living Room TV'),
        AudioDevice(name: 'b', description: 'Bedroom TV'),
      ];
      expect(matchAudioDevice('tv', ambiguous), ambiguous[0]);
    });

    test('returns null rather than guessing', () {
      expect(matchAudioDevice('soundbar', _devices), isNull);
      expect(matchAudioDevice('', _devices), isNull);
      expect(matchAudioDevice('   ', _devices), isNull);
      expect(matchAudioDevice('tv', const []), isNull);
    });
  });

  // The player's own menu remembers an output pick for later videos (#2744);
  // a remote's pick must stick the same way, and only once the core took it.
  group('applyRemoteAudioDevice', () {
    test('moves the player onto the device and remembers it for later videos', () async {
      final player = _AudioDevicePlayer();
      final remembered = <String>[];

      await applyRemoteAudioDevice(player, _devices[2], (name) async => remembered.add(name));

      expect(player.applied, ['wasapi/{0.0.0.222}']);
      expect(remembered, ['wasapi/{0.0.0.222}']);
    });

    test('remembers auto, which hands later videos back to automatic selection', () async {
      final remembered = <String>[];

      await applyRemoteAudioDevice(_AudioDevicePlayer(), AudioDevice.auto, (name) async => remembered.add(name));

      expect(remembered, ['auto']);
    });

    test('a device the player refuses is not remembered and does not throw', () async {
      final player = _AudioDevicePlayer(refuse: true);
      final remembered = <String>[];

      await applyRemoteAudioDevice(player, _devices[3], (name) async => remembered.add(name));

      expect(remembered, isEmpty);
    });
  });
}

class _AudioDevicePlayer implements Player {
  _AudioDevicePlayer({this.refuse = false});

  final bool refuse;
  final applied = <String>[];

  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    if (refuse) throw StateError('audio output refused');
    applied.add(device.name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
