import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'channel_matrix.dart';
import 'pcm_clip.dart';
import 'pcm_format.dart';
import 'sinc_kernel.dart';

/// Lifecycle of one independently controllable mixer voice.
enum MixerVoiceState { playing, paused, stopped, completed, disposed }

/// How a [PcmMixer] converts clips to its output sample rate.
enum PcmResampling {
  /// Kaiser-windowed sinc interpolation, low-passed below the lower of the
  /// two Nyquist frequencies so downsampling does not alias.
  sinc,

  /// Linear interpolation between adjacent frames. Cheaper, but it aliases
  /// when downsampling and leaves images when upsampling.
  linear,
}

/// A reusable, device-independent PCM clip mixer.
///
/// [play] starts an independent voice. In real-time mode (the default), mixed
/// S16LE chunks are emitted on [frames] using [chunk] as the audio clock, or
/// as an attached device clock pulls them (see [attachClock]). In manual mode
/// callers use [mix] to pull exact frame counts, which is useful for offline
/// rendering and deterministic tests.
final class PcmMixer {
  PcmMixer({
    this.format = const PcmFormat(),
    this.resampling = PcmResampling.sinc,
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

  /// How clips whose sample rate differs from [format]'s are converted.
  final PcmResampling resampling;

  /// Target duration of each real-time output chunk.
  final Duration chunk;

  /// Whether [play] drives [frames] from a periodic timer while no
  /// [MixerClock] is attached.
  final bool realtime;

  final int _chunkFrames;
  final Duration _timerPeriod;
  final List<MixerVoice> _voices = <MixerVoice>[];
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  Timer? _timer;
  MixerClock? _clock;
  int _chunksHandled = 0;
  int _frameRemainder = 0;
  bool _disposed = false;
  double _masterGain = 1;

  static const int _maxCatchUpChunks = 6;

  /// Mixed interleaved S16LE frames in [format].
  ///
  /// In real-time mode chunks are only emitted while at least one voice is
  /// playing; the stream goes quiet rather than carrying silence when every
  /// voice is paused or finished. Consumers that need a continuous signal
  /// must fill those gaps themselves. While a [MixerClock] is attached, the
  /// chunks are the ones it pulls, at its pace and in its chunk sizes.
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
      voice._signalComplete();
      _voices.remove(voice);
    } else if (realtime) {
      _startTimer();
    }
    return voice;
  }

  /// Mixes and advances [frameCount] output frames synchronously.
  ///
  /// Paused/stopped voices contribute silence. Samples are resampled as
  /// [resampling] selects, mapped onto the output channels by speaker layout,
  /// summed in floating point, gain-scaled, and clamped once at the output
  /// edge.
  Uint8List mix({int? frameCount}) {
    if (_disposed) throw StateError('PcmMixer has been disposed');
    final frames = frameCount ?? _chunkFrames;
    if (frames < 0) {
      throw ArgumentError.value(frames, 'frameCount', 'must be >= 0');
    }
    final (out, finished) = _mix(frames);
    for (final voice in finished) {
      voice._signalComplete();
    }
    return out;
  }

  (Uint8List, List<MixerVoice>) _mix(int frames) {
    final acc = Float64List(frames * format.channels);
    for (final voice in List<MixerVoice>.of(_voices)) {
      voice._mixInto(acc, frames, format);
    }
    final finished = _voices
        .where((voice) => voice.state == MixerVoiceState.completed)
        .toList();
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
    return (out, finished);
  }

  /// Drives the mixer from an external audio clock, such as a capture device,
  /// in place of the real-time timer.
  ///
  /// While the returned clock is attached, voices advance only as
  /// [MixerClock.pull] mixes frames, so they stay in step with that clock no
  /// matter how far it drifts from the system timer. Returns null when another
  /// clock is already attached.
  MixerClock? attachClock() {
    if (_disposed) throw StateError('PcmMixer has been disposed');
    if (_clock != null) return null;
    _stopTimer();
    return _clock = MixerClock._(this);
  }

  Uint8List _pull(int frames) {
    final playing = _hasPlayableVoice;
    // Same order as the timer: emit the chunk, then resolve onComplete.
    final (out, finished) = _mix(frames);
    if (playing && !_controller.isClosed) _controller.add(out);
    for (final voice in finished) {
      voice._signalComplete();
    }
    return out;
  }

  void _detach(MixerClock clock) {
    if (!identical(_clock, clock)) return;
    _clock = null;
    if (realtime && _hasPlayableVoice) _startTimer();
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
    _clock?._attached = false;
    _clock = null;
    for (final voice in List<MixerVoice>.of(_voices)) {
      voice.dispose();
    }
    _voices.clear();
    // A broadcast close() waits for paused listeners; do not hang on them.
    unawaited(_controller.close());
  }

  void _startTimer() {
    if (_timer != null || _disposed || _clock != null) return;
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
        // Queue the chunk before resolving onComplete for voices that ended
        // in it, so listeners never hear about the end ahead of the audio.
        final (out, finished) = _mix(frames);
        _controller.add(out);
        for (final voice in finished) {
          voice._signalComplete();
        }
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

/// An external clock driving a [PcmMixer]; see [PcmMixer.attachClock].
final class MixerClock {
  MixerClock._(this._mixer);

  final PcmMixer _mixer;
  bool _attached = true;

  /// Whether this clock still drives its mixer.
  bool get isAttached => _attached;

  /// Mixes, advances, and returns the next [frameCount] frames.
  ///
  /// While a voice is playing the chunk is also emitted on [PcmMixer.frames],
  /// so other listeners hear the same audio. After [detach], or once the mixer
  /// is disposed, this returns silence.
  Uint8List pull(int frameCount) {
    if (frameCount < 0) {
      throw ArgumentError.value(frameCount, 'frameCount', 'must be >= 0');
    }
    if (!_attached || _mixer._disposed) {
      return Uint8List(frameCount * _mixer.format.bytesPerFrame);
    }
    return _mixer._pull(frameCount);
  }

  /// Hands the mixer back to its real-time timer. Idempotent.
  void detach() {
    if (!_attached) return;
    _attached = false;
    _mixer._detach(this);
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
  late final Float64List _resampled = Float64List(clip.format.channels);
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
    _signalComplete();
  }

  bool get _isTerminal =>
      _state == MixerVoiceState.stopped ||
      _state == MixerVoiceState.completed ||
      _state == MixerVoiceState.disposed;

  void _completeNaturally() {
    // Resampling can step past the last frame; stop [position] at the end.
    _sourceFrame = clip.frameCount.toDouble();
    _state = MixerVoiceState.completed;
  }

  // Kept apart from [_completeNaturally] so the mixer can emit the final
  // chunk before resolving [onComplete].
  void _signalComplete() {
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
    final matrix = ChannelMatrix(clip.format.channels, outputFormat.channels);
    // At the same rate a whole-frame position stays whole: copy, don't filter.
    final direct =
        ratio == 1 && _sourceFrame == _sourceFrame.truncateToDouble();
    final kernel = direct || _mixer.resampling != PcmResampling.sinc
        ? null
        : SincKernel(clip.format.sampleRate, outputFormat.sampleRate);
    for (var frame = 0; frame < outputFrames; frame++) {
      if (_sourceFrame >= sourceFrames) {
        if (looping) {
          _sourceFrame %= sourceFrames;
        } else {
          _completeNaturally();
          break;
        }
      }

      if (direct) {
        _readFrame();
      } else if (kernel != null) {
        kernel.read(
          clip.samples,
          clip.format.channels,
          _sourceFrame,
          looping,
          _resampled,
        );
      } else {
        _readLinear();
      }
      matrix.mixInto(_resampled, output, frame * outputFormat.channels, _gain);
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

  void _readFrame() {
    final channels = clip.format.channels;
    final base = _sourceFrame.toInt() * channels;
    for (var channel = 0; channel < channels; channel++) {
      _resampled[channel] = clip.samples[base + channel].toDouble();
    }
  }

  void _readLinear() {
    final channels = clip.format.channels;
    final first = _sourceFrame.floor();
    var second = first + 1;
    if (second >= clip.frameCount) second = looping ? 0 : first;
    final fraction = _sourceFrame - first;
    for (var channel = 0; channel < channels; channel++) {
      final a = clip.samples[first * channels + channel].toDouble();
      final b = clip.samples[second * channels + channel].toDouble();
      _resampled[channel] = a + (b - a) * fraction;
    }
  }
}
