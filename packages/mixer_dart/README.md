# mixer_dart

Reusable, pure-Dart PCM mixing. It owns device-independent audio-graph
behavior: concurrent clip voices, gain, pause/resume/seek/loop controls,
speaker-layout channel mapping, sample rate conversion, summing, and S16LE
output clamping. It does not open microphones or speakers; route its output to
whatever sink you like.

Clips are resampled with a Kaiser-windowed sinc filter by default, which
low-passes below the output's Nyquist frequency so downsampling onto an 8 or
16 kHz voice bus does not alias. Pass `resampling: PcmResampling.linear` for
cheaper linear interpolation. Up- and down-mixing assume the WAVE/SMPTE channel
order for 1 to 8 channels and fold surrounds into stereo ITU-style, without the
LFE.

```dart
import 'package:mixer_dart/mixer_dart.dart';

final mixer = PcmMixer(
  format: const PcmFormat(sampleRate: 48000, channels: 2),
);
final voice = mixer.play(clip, gain: 0.8);
mixer.frames.listen(sendSomewhere);
```

By default a timer clocks the mix. When the output feeds a device with its own
clock, such as a microphone capture stream, let that device drive it instead
so the two never drift apart:

```dart
final clock = mixer.attachClock()!;
final frames = clock.pull(framesTheDeviceJustDelivered);
clock.detach(); // back to the timer
```

## License

MIT. See [LICENSE](LICENSE).
