// lib/packages/smart_media_player/waveform/analyzer/waveform_analyzer_fftw.dart
// v3.30.0 | FFTW band energy wrapper (frames×bands) + flattened 0..1 series

import 'dart:math' as math;
import 'package:guitartree/packages/smart_media_player/waveform/analyzer/fftw_bridge.dart';

class BandEnergySeries {
  final List<List<double>> left; // [frame][band]
  final List<List<double>> right; // [frame][band]
  final int sampleRate;
  final int bands;
  const BandEnergySeries(this.left, this.right, this.sampleRate, this.bands);
}

class WaveformAnalyzerFftwOptions {
  final int fftSize; // e.g., 2048~4096
  final int hopSize; // e.g., 512~2048 (fftSize/4~1/2)
  final int bands; // e.g., 4~8
  final bool aWeighting; // A-weighting on/off
  const WaveformAnalyzerFftwOptions({
    this.fftSize = 2048,
    this.hopSize = 512,
    this.bands = 4,
    this.aWeighting = false,
  });
}

class WaveformAnalyzerFftwOp {
  final FftwBridge _bridge = FftwBridge();

  /// frames×bands 결과(플랫 배열)를 [frame][band]로 바꿔서 제공
  Future<BandEnergySeries?> analyze({
    required List<double> pcmLeft,
    required List<double>? pcmRight,
    required int sampleRate,
    required WaveformAnalyzerFftwOptions options,
  }) async {
    try {
      final outL = <double>[];
      final outR = <double>[];
      final rc = _bridge.analyze(
        left: pcmLeft,
        right: pcmRight,
        sampleRate: sampleRate,
        fftSize: options.fftSize,
        hopSize: options.hopSize,
        bands: options.bands,
        aWeighting: options.aWeighting,
        outLeft: outL,
        outRight: outR,
        expectedFrames: (pcmLeft.length / options.hopSize).ceil(),
      );
      if (rc <= 0 || outL.isEmpty || outR.isEmpty) return null;

      final frames = (outL.length / options.bands).round();

      List<List<double>> to2D(List<double> flat) {
        final out = List.generate(
          frames,
          (_) => List.filled(options.bands, 0.0),
        );
        var idx = 0;
        for (var f = 0; f < frames; f++) {
          for (var b = 0; b < options.bands; b++) {
            out[f][b] = flat[idx++];
          }
        }
        return out;
      }

      return BandEnergySeries(
        to2D(outL),
        to2D(outR),
        sampleRate,
        options.bands,
      );
    } catch (_) {
      return null;
    }
  }

  /// 밴드별 가중치를 적용해 프레임별 단일값(0..1) 시퀀스로 납작화
  /// [weights] 합은 1.0 권장
  List<double> flattenWeighted(
    List<List<double>> framesBands,
    List<double> weights,
  ) {
    final bands = weights.length;
    if (framesBands.isEmpty) return const <double>[];
    final out = <double>[];
    for (final fb in framesBands) {
      double acc = 0;
      for (int b = 0; b < math.min(bands, fb.length); b++) {
        acc += fb[b] * weights[b];
      }
      out.add(acc.clamp(0.0, 1.0));
    }
    return out;
  }
}
