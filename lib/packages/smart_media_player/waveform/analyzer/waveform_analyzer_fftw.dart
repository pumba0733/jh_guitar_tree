// Waveform Analyzer (FFTW) — Dart wrapper (옵션)
import './fftw_bridge.dart';

class BandEnergySeries {
  final List<List<double>> left; // [frame][band]
  final List<List<double>> right; // [frame][band]
  final int sampleRate;
  final int bands;
  const BandEnergySeries(this.left, this.right, this.sampleRate, this.bands);
}

class WaveformAnalyzerFftwOptions {
  final int fftSize; // e.g., 4096
  final int hopSize; // default: fftSize/2
  final int bands; // 24~64
  final bool aWeighting;
  const WaveformAnalyzerFftwOptions({
    this.fftSize = 4096,
    int? hopSize,
    this.bands = 32,
    this.aWeighting = true,
  }) : hopSize = hopSize ?? 2048;
}

class WaveformAnalyzerFftw {
  final _bridge = FftwBridge();

  Future<BandEnergySeries> analyzeFloat32Stereo({
    required List<double> left,
    required List<double>? right,
    required int sampleRate,
    WaveformAnalyzerFftwOptions options = const WaveformAnalyzerFftwOptions(),
  }) async {
    final n = left.length;
    if (n <= options.fftSize) {
      return BandEnergySeries(const [], const [], sampleRate, options.bands);
    }
    final frames = 1 + (n - options.fftSize) ~/ options.hopSize;
    print(
      '[FFT] analyze start: n=$n, sr=$sampleRate, fft=${options.fftSize}, hop=${options.hopSize}, bands=${options.bands}, frames=$frames',
    );

    final outL = <double>[];
    final outR = <double>[];
    final rc = _bridge.analyze(
      left: left,
      right: right,
      sampleRate: sampleRate,
      fftSize: options.fftSize,
      hopSize: options.hopSize,
      bands: options.bands,
      aWeighting: options.aWeighting,
      outLeft: outL,
      outRight: outR,
      expectedFrames: frames,
    );

    print('[FFT] analyze rc=$rc, outL=${outL.length}, outR=${outR.length}');

    if (rc != 0) {
      return BandEnergySeries(const [], const [], sampleRate, options.bands);
    }

    List<List<double>> to2D(List<double> flat) {
      final out = List.generate(frames, (_) => List.filled(options.bands, 0.0));
      var idx = 0;
      for (var f = 0; f < frames; f++) {
        for (var b = 0; b < options.bands; b++) {
          out[f][b] = flat[idx++];
        }
      }
      return out;
    }

    return BandEnergySeries(to2D(outL), to2D(outR), sampleRate, options.bands);
  }
}
