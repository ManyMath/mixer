import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:mixer_dart/mixer_dart.dart';
import 'package:test/test.dart';

List<int> decode(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  return <int>[
    for (var i = 0; i < bytes.length ~/ 2; i++)
      view.getInt16(i * 2, Endian.little),
  ];
}

void main() {
  test('mixes voices and clamps once at the output edge', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);
    final mixer = PcmMixer(format: format, realtime: false);
    mixer.play(
      PcmClip(samples: Int16List.fromList([30000, -30000]), format: format),
    );
    mixer.play(
      PcmClip(samples: Int16List.fromList([10000, -10000]), format: format),
    );

    expect(decode(mixer.mix(frameCount: 2)), [32767, -32768]);
  });

  test('up-mixes mono and down-mixes stereo', () {
    const mono = PcmFormat(sampleRate: 8000, channels: 1);
    const stereo = PcmFormat(sampleRate: 8000, channels: 2);
    final up = PcmMixer(format: stereo, realtime: false)
      ..play(PcmClip(samples: Int16List.fromList([1000]), format: mono));
    expect(decode(up.mix(frameCount: 1)), [1000, 1000]);

    final down = PcmMixer(
      format: mono,
      realtime: false,
    )..play(PcmClip(samples: Int16List.fromList([1000, 3000]), format: stereo));
    expect(decode(down.mix(frameCount: 1)), [2000]);
  });

  test('linearly resamples a clip onto the output clock', () {
    const source = PcmFormat(sampleRate: 2, channels: 1);
    const output = PcmFormat(sampleRate: 4, channels: 1);
    final mixer = PcmMixer(format: output, realtime: false)
      ..play(
        PcmClip(samples: Int16List.fromList([0, 1000, 2000]), format: source),
      );

    expect(decode(mixer.mix(frameCount: 6)), [0, 500, 1000, 1500, 2000, 2000]);
  });

  test(
    'voice pause, seek, gain, loop, stop, and completion are independent',
    () async {
      const format = PcmFormat(sampleRate: 10, channels: 1);
      final mixer = PcmMixer(format: format, realtime: false);
      final voice = mixer.play(
        PcmClip(samples: Int16List.fromList([100, 200]), format: format),
        gain: 2,
        looping: true,
      );
      expect(decode(mixer.mix(frameCount: 3)), [200, 400, 200]);

      voice.pause();
      expect(decode(mixer.mix(frameCount: 1)), [0]);
      voice.seek(Duration.zero);
      voice.gain = 1;
      voice.looping = false;
      voice.resume();
      expect(decode(mixer.mix(frameCount: 2)), [100, 200]);
      await voice.onComplete;
      expect(voice.state, MixerVoiceState.completed);

      final other = mixer.play(
        PcmClip(samples: Int16List.fromList([1, 2]), format: format),
      );
      other.stop();
      expect(other.state, MixerVoiceState.stopped);
      expect(mixer.voices, isEmpty);
    },
  );

  test('master gain remains live', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);
    final mixer = PcmMixer(format: format, realtime: false)..masterGain = 0.5;
    mixer.play(
      PcmClip(samples: Int16List.fromList([1000, 1000]), format: format),
    );
    expect(decode(mixer.mix(frameCount: 2)), [500, 500]);
  });

  test('a looping voice reports a position within its clip', () {
    const source = PcmFormat(sampleRate: 16000, channels: 1);
    const output = PcmFormat(sampleRate: 8000, channels: 1);
    final mixer = PcmMixer(format: output, realtime: false);
    final voice = mixer.play(
      PcmClip(samples: Int16List(3), format: source),
      looping: true,
    );
    mixer.mix(frameCount: 2);
    expect(voice.position, lessThanOrEqualTo(voice.duration));
  });

  test('extreme finite gains clamp instead of throwing', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);
    final mixer = PcmMixer(format: format, realtime: false)..masterGain = 1e300;
    mixer.play(
      PcmClip(samples: Int16List.fromList([32767, -32768]), format: format),
      gain: 1e10,
    );
    expect(decode(mixer.mix(frameCount: 2)), [32767, -32768]);
  });

  test('real-time chunks carry fractional frames instead of drifting', () {
    // 11025 Hz * 20 ms is 220.5 frames per chunk.
    const format = PcmFormat(sampleRate: 11025, channels: 1);
    fakeAsync((async) {
      final mixer = PcmMixer(format: format);
      var frames = 0;
      mixer.frames.listen((chunk) => frames += chunk.length ~/ 2);
      mixer.play(
        PcmClip(samples: Int16List(format.sampleRate), format: format),
        looping: true,
      );
      async.elapse(const Duration(seconds: 10));
      expect(frames, 10 * format.sampleRate);
      mixer.dispose();
      async.flushMicrotasks();
    });
  });
}
