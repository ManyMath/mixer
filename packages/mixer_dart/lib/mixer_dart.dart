/// Pure-Dart, device-independent PCM mixing.
///
/// [PcmMixer] mixes any number of in-memory S16LE clips, resampling and
/// channel-adapting each voice to one output stream. Platform packages decide
/// whether that stream is sent to speakers, a virtual microphone, a file, or
/// another audio graph.
library;

export 'src/pcm_clip.dart';
export 'src/pcm_format.dart';
export 'src/pcm_mixer.dart';
