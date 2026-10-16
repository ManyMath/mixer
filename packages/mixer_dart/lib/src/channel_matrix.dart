import 'dart:math' as math;
import 'dart:typed_data';

enum _Speaker {
  frontLeft,
  frontRight,
  frontCenter,
  lowFrequency,
  backLeft,
  backRight,
  backCenter,
  sideLeft,
  sideRight,
}

// PcmFormat carries no channel mask, so assume the WAVE/SMPTE order for each
// count. Symphonia interleaves decoded channels in the same order.
const _layouts = <List<_Speaker>>[
  [_Speaker.frontCenter],
  [_Speaker.frontLeft, _Speaker.frontRight],
  [_Speaker.frontLeft, _Speaker.frontRight, _Speaker.frontCenter],
  [
    _Speaker.frontLeft,
    _Speaker.frontRight,
    _Speaker.backLeft,
    _Speaker.backRight,
  ],
  [
    _Speaker.frontLeft,
    _Speaker.frontRight,
    _Speaker.frontCenter,
    _Speaker.backLeft,
    _Speaker.backRight,
  ],
  [
    _Speaker.frontLeft,
    _Speaker.frontRight,
    _Speaker.frontCenter,
    _Speaker.lowFrequency,
    _Speaker.backLeft,
    _Speaker.backRight,
  ],
  [
    _Speaker.frontLeft,
    _Speaker.frontRight,
    _Speaker.frontCenter,
    _Speaker.lowFrequency,
    _Speaker.backCenter,
    _Speaker.sideLeft,
    _Speaker.sideRight,
  ],
  [
    _Speaker.frontLeft,
    _Speaker.frontRight,
    _Speaker.frontCenter,
    _Speaker.lowFrequency,
    _Speaker.backLeft,
    _Speaker.backRight,
    _Speaker.sideLeft,
    _Speaker.sideRight,
  ],
];

List<_Speaker>? _layout(int channels) =>
    channels <= _layouts.length ? _layouts[channels - 1] : null;

// ITU-style stereo fold-down weights (left, right); LFE is left out.
(double, double) _stereoWeights(_Speaker speaker) => switch (speaker) {
  _Speaker.frontLeft => (1, 0),
  _Speaker.frontRight => (0, 1),
  _Speaker.frontCenter => (math.sqrt1_2, math.sqrt1_2),
  _Speaker.lowFrequency => (0, 0),
  _Speaker.backLeft || _Speaker.sideLeft => (math.sqrt1_2, 0),
  _Speaker.backRight || _Speaker.sideRight => (0, math.sqrt1_2),
  _Speaker.backCenter => (0.5, 0.5),
};

/// Weights that map one frame of source channels onto the output channels.
final class ChannelMatrix {
  ChannelMatrix._(this.sourceChannels, this.outputChannels, this._weights);

  /// The shared matrix from [sourceChannels] to [outputChannels].
  factory ChannelMatrix(int sourceChannels, int outputChannels) =>
      _cache[(sourceChannels, outputChannels)] ??= ChannelMatrix._build(
        sourceChannels,
        outputChannels,
      );

  static final _cache = <(int, int), ChannelMatrix>{};

  final int sourceChannels;
  final int outputChannels;

  // One row of source weights per output channel; null when counts match.
  final Float64List? _weights;

  /// Adds [frame], one value per source channel, times [gain] to the output
  /// frame starting at [offset].
  void mixInto(Float64List frame, Float64List output, int offset, double gain) {
    final weights = _weights;
    if (weights == null) {
      for (var channel = 0; channel < outputChannels; channel++) {
        output[offset + channel] += frame[channel] * gain;
      }
      return;
    }
    var weight = 0;
    for (var channel = 0; channel < outputChannels; channel++) {
      var sum = 0.0;
      for (var source = 0; source < sourceChannels; source++) {
        sum += weights[weight++] * frame[source];
      }
      output[offset + channel] += sum * gain;
    }
  }

  static ChannelMatrix _build(int sourceChannels, int outputChannels) {
    if (sourceChannels == outputChannels) {
      return ChannelMatrix._(sourceChannels, outputChannels, null);
    }
    final weights = Float64List(sourceChannels * outputChannels);
    void add(int output, int source, double weight) =>
        weights[output * sourceChannels + source] += weight;

    final from = _layout(sourceChannels);
    final to = _layout(outputChannels);
    if (from == null || to == null) {
      // No known layout: average everything everywhere rather than drop any.
      weights.fillRange(0, weights.length, 1 / sourceChannels);
    } else if (sourceChannels == 1) {
      final center = to.indexOf(_Speaker.frontCenter);
      if (center >= 0) {
        add(center, 0, 1);
      } else {
        add(0, 0, 1);
        add(1, 0, 1);
      }
    } else if (outputChannels <= 2) {
      final left = Float64List(sourceChannels);
      final right = Float64List(sourceChannels);
      for (var source = 0; source < sourceChannels; source++) {
        final (l, r) = _stereoWeights(from[source]);
        left[source] = l;
        right[source] = r;
      }
      // Normalized rows keep a full-scale clip from clipping, and their
      // average is a plain mean of a stereo pair.
      final leftSum = left.reduce((a, b) => a + b);
      final rightSum = right.reduce((a, b) => a + b);
      for (var source = 0; source < sourceChannels; source++) {
        final l = left[source] / leftSum;
        final r = right[source] / rightSum;
        if (outputChannels == 2) {
          add(0, source, l);
          add(1, source, r);
        } else {
          add(0, source, (l + r) / 2);
        }
      }
    } else {
      for (var source = 0; source < sourceChannels; source++) {
        final speaker = from[source];
        final output = to.indexOf(speaker);
        if (output >= 0) {
          add(output, source, 1);
        } else if (speaker != _Speaker.lowFrequency) {
          final (l, r) = _stereoWeights(speaker);
          add(0, source, l);
          add(1, source, r);
        }
      }
    }
    return ChannelMatrix._(sourceChannels, outputChannels, weights);
  }
}
