import 'dart:async';
import 'dart:math' as math;
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

Int16List sine(double hz, int sampleRate, int frames) => Int16List.fromList([
  for (var i = 0; i < frames; i++)
    (10000 * math.sin(2 * math.pi * hz * i / sampleRate)).round(),
]);

double rms(List<int> samples) {
  var sum = 0.0;
  for (final sample in samples) {
    sum += sample * sample;
  }
  return math.sqrt(sum / samples.length);
}

double decibels(double ratio) => 20 * math.log(ratio) / math.ln10;

const mono48k = PcmFormat(sampleRate: 48000, channels: 1);

// Plays [clip] alone and renders [frames] frames of [output].
List<int> render(
  PcmClip clip,
  PcmFormat output,
  int frames, {
  PcmResampling resampling = PcmResampling.sinc,
  bool looping = false,
}) {
  final mixer = PcmMixer(
    format: output,
    realtime: false,
    resampling: resampling,
  )..play(clip, looping: looping);
  return decode(mixer.mix(frameCount: frames));
}

// Mixes a single frame between channel counts at the same rate.
List<int> mixFrame(List<int> frame, {required int from, required int to}) {
  final mixer = PcmMixer(
    format: PcmFormat(sampleRate: 8000, channels: to),
    realtime: false,
  );
  mixer.play(
    PcmClip(
      samples: Int16List.fromList(frame),
      format: PcmFormat(sampleRate: 8000, channels: from),
    ),
  );
  return decode(mixer.mix(frameCount: 1));
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

  test('down-mixes extra channels into a multi-channel output', () {
    const quad = PcmFormat(sampleRate: 8000, channels: 4);
    const stereo = PcmFormat(sampleRate: 8000, channels: 2);
    final mixer = PcmMixer(format: stereo, realtime: false)
      ..play(
        PcmClip(samples: Int16List.fromList([0, 0, 1000, 3000]), format: quad),
      );
    // Quad is FL FR BL BR; each rear folds in at sqrt(1/2) before the row is
    // normalized, so it lands at 0.4142 of its level.
    expect(decode(mixer.mix(frameCount: 1)), [414, 1243]);
  });

  test('a 5.1 center reaches both stereo channels equally', () {
    final out = mixFrame([0, 0, 10000, 0, 0, 0], from: 6, to: 2);
    expect(out[0], greaterThan(0));
    expect(out[1], out[0]);
  });

  test('LFE is left out of a stereo down-mix', () {
    expect(mixFrame([0, 0, 0, 20000, 0, 0], from: 6, to: 2), [0, 0]);
  });

  test('5.1 down-mixes to mono as the mean of its stereo fold-down', () {
    const s = math.sqrt1_2;
    const left = (1000 + 3000 * s + 5000 * s) / (1 + 2 * s);
    const right = (2000 + 3000 * s + 6000 * s) / (1 + 2 * s);
    expect(mixFrame([1000, 2000, 3000, 4000, 5000, 6000], from: 6, to: 1), [
      ((left + right) / 2).round(),
    ]);
  });

  test('stereo up-mixes to the 5.1 front pair only', () {
    expect(mixFrame([1000, 2000], from: 2, to: 6), [1000, 2000, 0, 0, 0, 0]);
  });

  test('mono up-mixes to the 5.1 center only', () {
    expect(mixFrame([1000], from: 1, to: 6), [0, 0, 1000, 0, 0, 0]);
  });

  test('7.1 folds its side pair into the 5.1 front pair', () {
    expect(
      mixFrame([100, 200, 300, 400, 500, 600, 7000, 8000], from: 8, to: 6),
      [
        (100 + 7000 * math.sqrt1_2).round(),
        (200 + 8000 * math.sqrt1_2).round(),
        300,
        400,
        500,
        600,
      ],
    );
  });

  test('channels without a known layout are averaged', () {
    final frame = [for (var i = 0; i < 10; i++) i * 100];
    expect(mixFrame(frame, from: 10, to: 2), [450, 450]);
  });

  test('linearly resamples a clip onto the output clock', () {
    const source = PcmFormat(sampleRate: 2, channels: 1);
    const output = PcmFormat(sampleRate: 4, channels: 1);
    final clip = PcmClip(
      samples: Int16List.fromList([0, 1000, 2000]),
      format: source,
    );
    final out = render(clip, output, 6, resampling: PcmResampling.linear);
    expect(out, [0, 500, 1000, 1500, 2000, 2000]);
  });

  test('sinc resampling passes a same-rate clip through exactly', () {
    const format = PcmFormat(sampleRate: 48000, channels: 2);
    final samples = Int16List.fromList([1, -2, 300, -400, 32767, -32768]);
    final clip = PcmClip(samples: samples, format: format);
    expect(render(clip, format, 6, looping: true), [...samples, ...samples]);
  });

  test('sinc resampling keeps a DC level away from the edges', () {
    final clip = PcmClip(
      samples: Int16List(4800)..fillRange(0, 4800, 10000),
      format: mono48k,
    );
    final out = render(clip, const PcmFormat(sampleRate: 44100), 4410);
    expect(out.sublist(100, 4300), everyElement(10000));
  });

  test('sinc resampling keeps a passband tone at its level', () {
    final input = sine(1000, 48000, 48000);
    final clip = PcmClip(samples: input, format: mono48k);
    final out = render(clip, const PcmFormat(sampleRate: 16000), 16000);
    final level = rms(out.sublist(1600, 14400)) / rms(input);
    expect(decibels(level), closeTo(0, 1));
  });

  test('sinc resampling rejects a tone above the output Nyquist frequency', () {
    // 7 kHz on an 8 kHz bus would alias to 1 kHz.
    final input = sine(7000, 48000, 48000);
    final clip = PcmClip(samples: input, format: mono48k);
    double level(PcmResampling resampling) {
      final out = render(
        clip,
        const PcmFormat(sampleRate: 8000),
        8000,
        resampling: resampling,
      );
      return rms(out.sublist(800, 7200)) / rms(input);
    }

    expect(decibels(level(PcmResampling.sinc)), lessThan(-40));
    expect(decibels(level(PcmResampling.linear)), greaterThan(-6));
  });

  test('a looping sinc-resampled clip has no seam at the wrap', () {
    // Ten whole periods, so the looped tone is continuous.
    final clip = PcmClip(samples: sine(1000, 48000, 480), format: mono48k);
    final out = render(
      clip,
      const PcmFormat(sampleRate: 44100),
      4410,
      looping: true,
    );
    final expected = sine(1000, 44100, 4410);
    for (var i = 0; i < out.length; i++) {
      expect(out[i], closeTo(expected[i], 3), reason: 'frame $i');
    }
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

  test('dispose does not wait for a paused frames listener', () async {
    final mixer = PcmMixer();
    final subscription = mixer.frames.listen((_) {})..pause();
    await mixer.dispose().timeout(const Duration(seconds: 1));
    await subscription.cancel();
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

  test('a finished resampled voice reports its duration as position', () {
    const source = PcmFormat(sampleRate: 44100, channels: 1);
    const output = PcmFormat(sampleRate: 48000, channels: 1);
    final mixer = PcmMixer(format: output, realtime: false);
    final voice = mixer.play(PcmClip(samples: Int16List(441), format: source));
    mixer.mix(frameCount: 1000);
    expect(voice.state, MixerVoiceState.completed);
    expect(voice.position, voice.duration);
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

  test('a muted mix stays silent when a voice gain overflows', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);
    final mixer = PcmMixer(format: format, realtime: false)..masterGain = 0;
    mixer.play(
      PcmClip(samples: Int16List.fromList([32767]), format: format),
      gain: 1e305,
    );
    expect(decode(mixer.mix(frameCount: 1)), [0]);
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

  test('a voice completes after its last chunk is emitted', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);
    fakeAsync((async) {
      final mixer = PcmMixer(format: format);
      final events = <String>[];
      mixer.frames.listen((_) => events.add('chunk'));
      // 240 frames span two 20 ms chunks of 160.
      final voice = mixer.play(
        PcmClip(samples: Int16List(240), format: format),
      );
      voice.onComplete.then((_) => events.add('complete'));
      async.elapse(const Duration(milliseconds: 100));
      expect(events, ['chunk', 'chunk', 'complete']);
      mixer.dispose();
      async.flushMicrotasks();
    });
  });

  test('real-time output keeps pace with a non-millisecond chunk', () async {
    // Real timers round periods to whole milliseconds and fake_async does not,
    // so this one runs on the wall clock.
    const format = PcmFormat(sampleRate: 48000, channels: 1);
    final mixer = PcmMixer(
      format: format,
      chunk: const Duration(microseconds: 10667), // 512 frames
    );
    var frames = 0;
    mixer.frames.listen((chunk) => frames += chunk.length ~/ 2);
    final elapsed = Stopwatch()..start();
    mixer.play(
      PcmClip(samples: Int16List(format.sampleRate), format: format),
      looping: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await mixer.dispose();
    final due =
        elapsed.elapsedMicroseconds *
        format.sampleRate ~/
        Duration.microsecondsPerSecond;
    expect(frames, inInclusiveRange(due ~/ 2, due + 512));
  });

  group('attached clock', () {
    const format = PcmFormat(sampleRate: 8000, channels: 1);

    test('replaces the timer: voices advance only as it pulls', () {
      fakeAsync((async) {
        final mixer = PcmMixer(format: format);
        final emitted = <int>[];
        mixer.frames.listen((chunk) => emitted.add(chunk.length ~/ 2));
        final clock = mixer.attachClock()!;
        final voice = mixer.play(
          PcmClip(samples: Int16List(format.sampleRate), format: format),
        );

        async.elapse(const Duration(seconds: 1));
        expect(emitted, isEmpty);
        expect(voice.position, Duration.zero);

        expect(clock.pull(80).length, 160);
        async.flushMicrotasks();
        expect(emitted, [80]);
        expect(voice.position, const Duration(milliseconds: 10));
        mixer.dispose();
        async.flushMicrotasks();
      });
    });

    test('is exclusive until detached, then the timer resumes', () {
      fakeAsync((async) {
        final mixer = PcmMixer(format: format);
        var emitted = 0;
        mixer.frames.listen((chunk) => emitted += chunk.length ~/ 2);
        final clock = mixer.attachClock()!;
        expect(mixer.attachClock(), isNull);
        mixer.play(
          PcmClip(samples: Int16List(format.sampleRate), format: format),
        );

        clock.detach();
        expect(clock.isAttached, isFalse);
        async.elapse(const Duration(milliseconds: 100));
        expect(emitted, 800);
        expect(mixer.attachClock(), isNotNull);
        mixer.dispose();
        async.flushMicrotasks();
      });
    });

    test('emits a voice\'s last chunk before resolving onComplete', () async {
      final mixer = PcmMixer(format: format);
      final clock = mixer.attachClock()!;
      final events = <String>[];
      mixer.frames.listen((_) => events.add('chunk'));
      final voice = mixer.play(
        PcmClip(samples: Int16List.fromList([1, 2, 3]), format: format),
      );
      unawaited(voice.onComplete.then((_) => events.add('complete')));

      expect(decode(clock.pull(4)), [1, 2, 3, 0]);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['chunk', 'complete']);
      await mixer.dispose();
    });

    test('pulls silence once the mixer is disposed', () async {
      final mixer = PcmMixer(format: const PcmFormat(channels: 2));
      final clock = mixer.attachClock()!;
      await mixer.dispose();
      expect(clock.isAttached, isFalse);
      expect(clock.pull(10), Uint8List(40));
    });
  });
}
