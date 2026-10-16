import 'dart:math' as math;
import 'dart:typed_data';

/// A Kaiser-windowed sinc low-pass filter for one pair of sample rates,
/// tabulated at evenly spaced fractional positions.
final class SincKernel {
  SincKernel._(this.taps, this._table);

  /// The shared kernel for resampling [sourceRate] to [outputRate].
  factory SincKernel(int sourceRate, int outputRate) =>
      _cache[(sourceRate, outputRate)] ??= SincKernel._build(
        sourceRate,
        outputRate,
      );

  static final _cache = <(int, int), SincKernel>{};

  static const int _phases = 256;
  static const int _zeroCrossings = 8;
  static const double _beta = 8;

  /// Source frames read per output frame.
  final int taps;

  // Rows of [taps] weights for fractions 0, 1/_phases, ..., 1.
  final Float64List _table;

  /// Writes the value of each channel of interleaved [samples] at the
  /// fractional frame [position] into [frame].
  ///
  /// Frames before the start or past the end are silent, unless [looping]
  /// wraps them around the clip.
  void read(
    Int16List samples,
    int channels,
    double position,
    bool looping,
    Float64List frame,
  ) {
    final frames = samples.length ~/ channels;
    final whole = position.floor();
    final scaled = (position - whole) * _phases;
    final phase = scaled.floor();
    final fraction = scaled - phase;
    final row = phase * taps;
    final start = whole - taps ~/ 2 + 1;
    final inside = start >= 0 && start + taps <= frames;
    frame.fillRange(0, channels, 0);
    for (var tap = 0; tap < taps; tap++) {
      var source = start + tap;
      if (!inside) {
        if (looping) {
          source %= frames;
        } else if (source < 0 || source >= frames) {
          continue;
        }
      }
      final a = _table[row + tap];
      final weight = a + (_table[row + taps + tap] - a) * fraction;
      final base = source * channels;
      for (var channel = 0; channel < channels; channel++) {
        frame[channel] += weight * samples[base + channel];
      }
    }
  }

  static SincKernel _build(int sourceRate, int outputRate) {
    final ratio = sourceRate / outputRate;
    // Downsampling moves the cutoff below the output's Nyquist frequency,
    // which stretches the kernel over more source frames.
    final cutoff = ratio > 1 ? 0.95 / ratio : 1.0;
    final halfWidth = _zeroCrossings / cutoff;
    final taps = 2 * halfWidth.ceil();
    final table = Float64List((_phases + 1) * taps);
    for (var phase = 0; phase <= _phases; phase++) {
      final row = phase * taps;
      var sum = 0.0;
      for (var tap = 0; tap < taps; tap++) {
        final x = tap - taps ~/ 2 + 1 - phase / _phases;
        final r = x / halfWidth;
        if (r.abs() >= 1) continue;
        final weight =
            _sinc(cutoff * x) * _besselI0(_beta * math.sqrt(1 - r * r));
        table[row + tap] = weight;
        sum += weight;
      }
      // Unity gain at DC for every fraction.
      for (var tap = 0; tap < taps; tap++) {
        table[row + tap] /= sum;
      }
    }
    return SincKernel._(taps, table);
  }

  static double _sinc(double x) {
    if (x == 0) return 1;
    final angle = math.pi * x;
    return math.sin(angle) / angle;
  }

  static double _besselI0(double x) {
    final quarter = x * x / 4;
    var term = 1.0;
    var sum = 1.0;
    for (var k = 1; term > sum * 1e-17; k++) {
      term *= quarter / (k * k);
      sum += term;
    }
    return sum;
  }
}
