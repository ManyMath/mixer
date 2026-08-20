import 'dart:typed_data';

import 'pcm_format.dart';

/// An immutable-by-contract, in-memory interleaved S16LE audio clip.
final class PcmClip {
  PcmClip({required this.samples, required this.format})
    : assert(
        samples.length % format.channels == 0,
        'samples must contain complete interleaved frames',
      );

  /// Interleaved signed 16-bit samples.
  ///
  /// Callers must not mutate this list while a voice is playing it.
  final Int16List samples;

  /// The clip's source format. It may differ from a mixer's output format.
  final PcmFormat format;

  /// Number of frames (one sample per channel).
  int get frameCount => samples.length ~/ format.channels;

  /// The clip's duration.
  Duration get duration => Duration(
    microseconds:
        frameCount * Duration.microsecondsPerSecond ~/ format.sampleRate,
  );

  /// Encodes the samples as interleaved little-endian signed 16-bit bytes.
  Uint8List toBytes() {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }

  /// Decodes raw interleaved S16LE bytes into a private sample buffer.
  factory PcmClip.fromBytes(Uint8List bytes, PcmFormat format) {
    final samples = Int16List(bytes.length ~/ 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return PcmClip(samples: samples, format: format);
  }
}
