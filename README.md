# mixer

Reusable, pure-Dart PCM mixing for ManyMath audio projects.

`mixer_dart` owns device-independent audio-graph behavior: concurrent clip
voices, gain, pause/resume/seek/loop controls, channel adaptation, linear sample
rate conversion, summing, and S16LE output clamping. It intentionally does not
open microphones or speakers. Packages such as `soundboard` route its output to
`sound_dart`, `microphone_dart`, virtual devices, files, or network transports.

```dart
final mixer = PcmMixer(
  format: const PcmFormat(sampleRate: 48000, channels: 2),
);
final voice = mixer.play(clip, gain: 0.8);
mixer.frames.listen(sendSomewhere);
```

The repository uses the same Dart-workspace and Melos layout as the other
projects under `~/src/hardware`. CI is intentionally not configured yet.
