import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm_clip.dart';
import 'pcm_format.dart';

/// Lifecycle of one independently controllable mixer voice.
enum MixerVoiceState { playing, paused, stopped, completed, disposed }

/// A reusable, device-independent PCM clip mixer.
///
/// [play] starts an independent voice. In real-time mode (the default), mixed
/// S16LE chunks are emitted on [frames] using [chunk] as the audio clock. In
/// manual mode callers use [mix] to pull exact frame counts, which is useful
/// for offline rendering and deterministic tests.
final class PcmMixer {
  PcmMixer({
    this.format = const PcmFormat(),
    this.chunk = const Duration(milliseconds: 20),
    this.realtime = true,
  }) : assert(chunk > Duration.zero, 'chunk must be positive'),
       _chunkFrames = math.max(
         1,
         format.sampleRate *
             chunk.inMicroseconds ~/
             Duration.microsecondsPerSecond,
       ),
       _timerPeriod = Duration(milliseconds: math.max(1, chunk.inMilliseconds));

  /// Format emitted by [frames] and [mix].
  final PcmFormat format;

  /// Target duration of each real-time output chunk.
  final Duration chunk;

  /// Whether [play] drives [frames] from a periodic timer.
  final bool realtime;

  final int _chunkFrames;
  final Duration _timerPeriod;
  final List<MixerVoice> _voices = <MixerVoice>[];
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  Timer? _timer;
  int _chunksHandled = 0;
  int _frameRemainder = 0;
  bool _disposed = false;
  double _masterGain = 1;

  static const int _maxCatchUpChunks = 6;

  /// Mixed interleaved S16LE frames in [format].
  Stream<Uint8List> get frames => _controller.stream;

  /// Live voices, including paused voices, as a read-only snapshot.
  List<MixerVoice> get voices => List<MixerVoice>.unmodifiable(_voices);

  /// Linear gain applied after all voices have been summed.
  double get masterGain => _masterGain;
  set masterGain(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'value', 'must be finite and >= 0');
    }
    _masterGain = value;
  }

  /// Starts an independent voice for [clip].
  MixerVoice play(PcmClip clip, {double gain = 1, bool looping = false}) {
    if (_disposed) throw StateError('PcmMixer has been disposed');
    final voice = MixerVoice._(this, clip, gain: gain, looping: looping);
    _voices.add(voice);
    if (clip.frameCount == 0) {
      voice._completeNaturally();
      _voices.remove(voice);
    } else if (realtime) {
      _startTimer();
    }
    return voice;
  }

  /// Mixes and advances [frameCount] output frames synchronously.
  ///
  /// Paused/stopped voices contribute silence. Samples are linearly resampled,
  /// channel-adapted, summed in floating point, gain-scaled, and clamped once
  /// at the output edge.
  Uint8List mix({int? frameCount}) {
    if (_disposed) throw StateError('PcmMixer has been disposed');
    final frames = frameCount ?? _chunkFrames;
    if (frames < 0) {
      throw ArgumentError.value(frames, 'frameCount', 'must be >= 0');
    }
    final acc = Float64List(frames * format.channels);
    for (final voice in List<MixerVoice>.of(_voices)) {
      voice._mixInto(acc, frames, format);
    }
    _voices.removeWhere((voice) => voice._isTerminal);

    final out = Uint8List(acc.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < acc.length; i++) {
      // Clamp before rounding: an extreme gain can push the sum to infinity.
      // Infinity times zero is NaN, which clamp() would send to full scale.
      final value = acc[i] * _masterGain;
      final scaled = value.isNaN ? 0 : value.clamp(-32768.0, 32767.0).round();
      view.setInt16(i * 2, scaled, Endian.little);
    }
    return out;
  }

  /// Stops all active and paused voices.
  void stopAll() {
    for (final voice in List<MixerVoice>.of(_voices)) {
      voice.stop();
    }
    _voices.clear();
    _stopTimer();
  }

  /// Releases the timer, voices, and stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopTimer();
    for (final voice in List<MixerVoice>.of(_voices)) {
      voice.dispose();
    }
    _voices.clear();
    // A broadcast close() waits for paused listeners; do not hang on them.
    unawaited(_controller.close());
  }

  void _startTimer() {
    if (_timer != null || _disposed) return;
    _chunksHandled = 0;
    _frameRemainder = 0;
    _timer = Timer.periodic(_timerPeriod, _tick);
  }

  void _tick(Timer timer) {
    if (_disposed) return;
    // Timers only run on whole milliseconds, so count chunks from the elapsed
    // periods rather than assuming one chunk per tick.
    final chunks =
        timer.tick * _timerPeriod.inMicroseconds ~/ chunk.inMicroseconds;
    var due = chunks - _chunksHandled;
    _chunksHandled = chunks;
    if (due > _maxCatchUpChunks) due = _maxCatchUpChunks;
    for (var i = 0; i < due && _hasPlayableVoice; i++) {
      final frames = _nextChunkFrames();
      if (frames > 0 && !_controller.isClosed) {
        _controller.add(mix(frameCount: frames));
      }
    }
    if (!_hasPlayableVoice) _stopTimer();
  }

  // A chunk rarely holds a whole number of frames (11025 Hz * 20 ms = 220.5),
  // so carry the remainder instead of letting the clock run slow.
  int _nextChunkFrames() {
    _frameRemainder += chunk.inMicroseconds * format.sampleRate;
    final frames = _frameRemainder ~/ Duration.microsecondsPerSecond;
    _frameRemainder -= frames * Duration.microsecondsPerSecond;
    return frames;
  }

  bool get _hasPlayableVoice =>
      _voices.any((voice) => voice.state == MixerVoiceState.playing);

  void _voiceResumed() {
    if (realtime) _startTimer();
  }

  void _remove(MixerVoice voice) {
    _voices.remove(voice);
    if (!_hasPlayableVoice) _stopTimer();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

/// One independently controllable playback in a [PcmMixer].
final class MixerVoice {
  MixerVoice._(
    this._mixer,
    this.clip, {
    required double gain,
    required this.looping,
  }) : _gain = gain {
    this.gain = gain;
  }

  final PcmMixer _mixer;

  /// Source clip for this voice.
  final PcmClip clip;

  final Completer<void> _completion = Completer<void>();
  MixerVoiceState _state = MixerVoiceState.playing;
  double _sourceFrame = 0;
  double _gain;

  /// Whether the source repeats until stopped.
  bool looping;

  MixerVoiceState get state => _state;
  bool get isPlaying => _state == MixerVoiceState.playing;

  /// Linear gain applied before the mixer's master gain.
  double get gain => _gain;
  set gain(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'value', 'must be finite and >= 0');
    }
    _gain = value;
  }

  /// Current source position.
  Duration get position => Duration(
    microseconds:
        _sourceFrame.round() *
        Duration.microsecondsPerSecond ~/
        clip.format.sampleRate,
  );

  Duration get duration => clip.duration;

  /// Completes when the voice reaches its end naturally.
  Future<void> get onComplete => _completion.future;

  void pause() {
    if (_state == MixerVoiceState.playing) _state = MixerVoiceState.paused;
  }

  void resume() {
    if (_state == MixerVoiceState.paused) {
      _state = MixerVoiceState.playing;
      _mixer._voiceResumed();
    }
  }

  /// Seeks within the source; seeking a completed/stopped voice does not
  /// restart it.
  void seek(Duration position) {
    if (_state == MixerVoiceState.disposed) return;
    final micros = position.inMicroseconds.clamp(
      0,
      clip.duration.inMicroseconds,
    );
    _sourceFrame =
        micros * clip.format.sampleRate / Duration.microsecondsPerSecond;
  }

  void stop() {
    if (_isTerminal) return;
    _state = MixerVoiceState.stopped;
    _mixer._remove(this);
  }

  void dispose() {
    if (_state == MixerVoiceState.disposed) return;
    _state = MixerVoiceState.disposed;
    _mixer._remove(this);
    if (!_completion.isCompleted) _completion.complete();
  }

  bool get _isTerminal =>
      _state == MixerVoiceState.stopped ||
      _state == MixerVoiceState.completed ||
      _state == MixerVoiceState.disposed;

  void _completeNaturally() {
    // Resampling can step past the last frame; stop [position] at the end.
    _sourceFrame = clip.frameCount.toDouble();
    _state = MixerVoiceState.completed;
    if (!_completion.isCompleted) _completion.complete();
  }

  void _mixInto(Float64List output, int outputFrames, PcmFormat outputFormat) {
    if (_state != MixerVoiceState.playing) return;
    final sourceFrames = clip.frameCount;
    if (sourceFrames == 0) {
      _completeNaturally();
      return;
    }
    final ratio = clip.format.sampleRate / outputFormat.sampleRate;
    for (var frame = 0; frame < outputFrames; frame++) {
      if (_sourceFrame >= sourceFrames) {
        if (looping) {
          _sourceFrame %= sourceFrames;
        } else {
          _completeNaturally();
          break;
        }
      }

      final first = _sourceFrame.floor();
      var second = first + 1;
      if (second >= sourceFrames) second = looping ? 0 : first;
      final fraction = _sourceFrame - first;
      final outputBase = frame * outputFormat.channels;
      for (var channel = 0; channel < outputFormat.channels; channel++) {
        final a = _sampleAt(first, channel, outputFormat.channels);
        final b = _sampleAt(second, channel, outputFormat.channels);
        output[outputBase + channel] += (a + (b - a) * fraction) * _gain;
      }
      _sourceFrame += ratio;
    }
    if (_sourceFrame >= sourceFrames) {
      if (looping) {
        // Wrap now so [position] never reports past the end between mixes.
        _sourceFrame %= sourceFrames;
      } else {
        _completeNaturally();
      }
    }
  }

  double _sampleAt(int frame, int outputChannel, int outputChannels) {
    final sourceChannels = clip.format.channels;
    final base = frame * sourceChannels;
    if (sourceChannels == outputChannels) {
      return clip.samples[base + outputChannel].toDouble();
    }
    if (sourceChannels < outputChannels) {
      return clip.samples[base + (outputChannel % sourceChannels)].toDouble();
    }
    // Fold the extra source channels onto the outputs instead of dropping
    // them; a mono output averages every channel.
    var sum = 0.0;
    var count = 0;
    for (
      var channel = outputChannel;
      channel < sourceChannels;
      channel += outputChannels
    ) {
      sum += clip.samples[base + channel];
      count++;
    }
    return sum / count;
  }
}
