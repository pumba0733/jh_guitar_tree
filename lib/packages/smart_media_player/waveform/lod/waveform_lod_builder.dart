// 아주 단순한 LOD 생성기 (FFTW band 에너지 → 저/중/고 해상도 시퀀스)
import '../analyzer/waveform_analyzer_fftw.dart'
    show WaveformAnalyzerFftw, WaveformAnalyzerFftwOptions, BandEnergySeries;


class _LodOut {
  final List<double> lowL, midL, highL;
  _LodOut(this.lowL, this.midL, this.highL);
}

class WaveformLodBuilder {
  _LodOut buildFromBands(BandEnergySeries bands) {
    if (bands.left.isEmpty) return _LodOut(const [], const [], const []);

    // 프레임별 전체 대역 RMS (왼쪽 기준)
    final frames = bands.left.length;
    final bcnt = bands.bands;
    final energy = List<double>.filled(frames, 0.0);
    for (var f = 0; f < frames; f++) {
      double s = 0.0;
      for (var b = 0; b < bcnt; b++) {
        final v = bands.left[f][b].clamp(0.0, double.infinity);
        s += v * v;
      }
      energy[f] = (s / bcnt).sqrt();
    }

    // 간단 downsample: high=원본, mid=1/4, low=1/16
    List<double> down(List<double> src, int factor) {
      if (factor <= 1 || src.length < 2) return List<double>.from(src);
      final outLen = (src.length / factor).ceil();
      final out = List<double>.filled(outLen, 0.0);
      var o = 0;
      for (var i = 0; i < src.length; i += factor) {
        double s = 0.0;
        var c = 0;
        for (var k = i; k < src.length && k < i + factor; k++) {
          s += src[k];
          c++;
        }
        out[o++] = (c > 0) ? s / c : 0.0;
      }
      return out;
    }

    final high = energy;
    final mid = down(energy, 4);
    final low = down(energy, 16);
    return _LodOut(low, mid, high);
  }
}

extension on double {
  double sqrt() => this <= 0 ? 0.0 : MathHelper.sqrt(this);
}

class MathHelper {
  static double sqrt(double x) => x > 0 ? x.toDouble().sqrt() : 0.0;
}
