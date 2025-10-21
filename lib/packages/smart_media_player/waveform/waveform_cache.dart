// v3.31.1-streamfix | JustWaveform(Stream) API 맞춤 버전
// - extract(...) → Stream<WaveformProgress>
// - await for 로 진행률 수신 & 최종 Waveform 회수
// - 이전 오류( progressCallback, await stream, stream을 Waveform로 사용 ) 전부 해결

import 'dart:io';
import 'dart:math' as math;
import 'dart:developer' as dev;

import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;

typedef WaveformProgressCallback = void Function(double p);

class WaveformLoadResult {
  final List<double> rmsL; // 0..1
  final List<double> rmsR; // 0..1
  final List<double> signedL; // -1..+1 (옵션: 현재 미사용)
  final List<double> signedR; // -1..+1 (옵션: 현재 미사용)
  const WaveformLoadResult({
    required this.rmsL,
    required this.rmsR,
    required this.signedL,
    required this.signedR,
  });
}

class WaveformCache {
  WaveformCache._();
  static final WaveformCache instance = WaveformCache._();

  Future<WaveformLoadResult> loadOrBuildStereoVectors({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int? targetSamples,
    Duration? durationHint,
    WaveformProgressCallback? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    onProgress?.call(0.02);
    dev.log(
      '[CACHE] start key=$cacheKey, durHint=${durationHint?.inMilliseconds}ms',
    );

    // 1) JustWaveform: Stream<WaveformProgress> 순회
    final tmpWavPath = p.join(cacheDir, '$cacheKey.jw.cache');
    final progressStream = JustWaveform.extract(
      audioInFile: File(mediaPath),
      waveOutFile: File(tmpWavPath),
    );

    Waveform? wf;
    await for (final e in progressStream) {
      // 진행률 콜백 (0.0..1.0)
      onProgress?.call((e.progress).clamp(0.0, 1.0));
      if (e.waveform != null) {
        wf = e.waveform!;
      }
    }
    // 방어: 혹시 스트림이 끝났는데도 waveform이 없다면 실패 처리
    if (wf == null) {
      onProgress?.call(1.0);
      throw StateError(
        'JustWaveform.extract() did not produce a Waveform for $mediaPath',
      );
    }

    // 2) PCM → RMS 시퀀스
    final n = wf!.data.length;
    final ts = (targetSamples ?? math.min(60000, n)).clamp(512, 300000);
    final hop = (n / ts).floor().clamp(1, n);
    final win = (hop * 2).clamp(2, n);
    dev.log('[CACHE] n=$n ts=$ts hop=$hop win=$win');

    final rms = _rmsSeriesFromWave(wf!, win, hop);
    final rmsL = rms;
    final rmsR = List<double>.from(rms);

    // (옵션) 시그널 시각 디버깅용 signed 시퀀스
    final signed = _signedSeriesFromWave(wf!, win, hop);
    final signedL = signed;
    final signedR = List<double>.from(signed);

    onProgress?.call(1.0);
    sw.stop();
    dev.log('[CACHE] done in ${sw.elapsedMilliseconds}ms, rms=${rmsL.length}');
    return WaveformLoadResult(
      rmsL: rmsL,
      rmsR: rmsR,
      signedL: signedL,
      signedR: signedR,
    );
  }

  // === Helpers ===

  List<double> _rmsSeriesFromWave(Waveform wf, int win, int hop) {
    final maxAbs = wf.data
        .fold<int>(1, (m, v) => v.abs() > m ? v.abs() : m)
        .toDouble();
    final out = <double>[];
    final N = wf.data.length;
    for (int i = 0; i + win <= N; i += hop) {
      double acc2 = 0.0;
      for (int k = 0; k < win; k++) {
        final s = (wf.data[i + k] / maxAbs);
        acc2 += s * s;
      }
      final rms = math.sqrt(acc2 / win).clamp(0.0, 1.0);
      out.add(rms);
    }
    if (out.isEmpty) out.add(0.0);
    return out;
  }

  List<double> _signedSeriesFromWave(Waveform wf, int win, int hop) {
    final maxAbs = wf.data
        .fold<int>(1, (m, v) => v.abs() > m ? v.abs() : m)
        .toDouble();
    final out = <double>[];
    bool sign = true;
    final N = wf.data.length;
    for (int i = 0; i + win <= N; i += hop) {
      double m = 0.0;
      for (int k = 0; k < win; k++) {
        final v = (wf.data[i + k] / maxAbs).abs();
        if (v > m) m = v;
      }
      out.add(sign ? m : -m);
      sign = !sign;
    }
    if (out.isEmpty) out.add(0.0);
    return out;
  }
}
