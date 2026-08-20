/// The sample rate and channel layout of interleaved signed 16-bit PCM.
final class PcmFormat {
  const PcmFormat({this.sampleRate = 48000, this.channels = 1})
    : assert(sampleRate > 0, 'sampleRate must be positive'),
      assert(channels > 0, 'channels must be positive');

  /// Samples per second, per channel.
  final int sampleRate;

  /// Number of interleaved channels.
  final int channels;

  /// Bytes occupied by one interleaved frame.
  int get bytesPerFrame => channels * 2;

  @override
  bool operator ==(Object other) =>
      other is PcmFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels;

  @override
  int get hashCode => Object.hash(sampleRate, channels);

  @override
  String toString() => 'PcmFormat($sampleRate Hz, $channels ch, S16LE)';
}
