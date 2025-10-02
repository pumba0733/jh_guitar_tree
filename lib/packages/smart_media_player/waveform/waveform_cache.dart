// lib/packages/smart_media_player/waveform/waveform_cache.dart
// v1.85.2 | Real Waveform Cache (just_waveform)
// - 입력: mediaPath, cacheDir, cacheKey
// - 처리: <cacheDir>/<cacheKey>.wave 캐시 사용. 없으면 추출 후 저장.
// - 출력: 0..1 정규화된 peaks (기본 800 bars)
//   * zoom: 100 px/sec (기본값) → 충분한 해상도
//
// 참고 API (0.0.7):
//  - JustWaveform.extract(...): Stream<WaveformProgress> (progress, waveform?)
//  - JustWaveform.parse(File): Future<Waveform>  (캐시 읽기)
//  - Waveform.getPixelMin/Max, positionToPixel, flags(16/8bit), length, duration

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';

import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;

typedef WaveformProgressCallback = void Function(double percent);

class WaveformCache {
  WaveformCache._();
  static final instance = WaveformCache._();

  Future<List<double>> loadOrBuild({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int targetBars = 800,
    WaveformProgressCallback? onProgress,
  }) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final wavePath = p.join(cacheDir, '$cacheKey.wave');
    final waveFile = File(wavePath);

    // 1) 캐시 있으면 바로 파싱
    if (await waveFile.exists()) {
      try {
        final wf = await JustWaveform.parse(waveFile);
        return _waveformToPeaks(wf, targetBars: targetBars);
      } catch (_) {
        // 손상 시 재생성
      }
    }

    // 2) 추출 진행
    Waveform? lastWave;
    final stream = JustWaveform.extract(
      audioInFile: File(mediaPath),
      waveOutFile: waveFile,
      // zoom 기본값 사용(WaveformZoom.pixelsPerSecond(100))
    );
    final c = Completer<void>();
    stream.listen(
      (e) {
        onProgress?.call(e.progress);
        if (e.waveform != null) {
          lastWave = e.waveform;
        }
      },
      onError: (err) => c.completeError(err),
      onDone: () => c.complete(),
      cancelOnError: true,
    );
    await c.future;

    // 3) 결과 사용(스트림 내 객체 있으면 그거 사용, 없으면 파일 파싱)
    final wf = lastWave ?? await JustWaveform.parse(waveFile);
    onProgress?.call(1.0);
    return _waveformToPeaks(wf, targetBars: targetBars);
  }

  /// Waveform → 0..1 정규화 막대
  List<double> _waveformToPeaks(Waveform wf, {int targetBars = 800}) {
    // 픽셀(=데이터 포인트) 개수
    final N = wf.length;
    if (N <= 0) return const [];

    // 16bit/8bit 정규화 범위
    final is16 = wf.flags == 0; // 0:16bit, 1:8bit
    final maxAbs = is16 ? 32768.0 : 128.0;

    // 다운샘플링: 픽셀들을 targetBars 구간으로 나눠 각 구간의 최대 진폭 사용
    final step = (N / targetBars).clamp(1, N.toDouble());
    final peaks = <double>[];
    var i = 0.0;
    while (i < N) {
      final start = i.floor();
      final end = math.min((i + step).ceil(), N);
      var peak = 0.0;
      for (var idx = start; idx < end; idx++) {
        // getPixelMin/Max는 음수/양수 진폭. 절대값 큰 쪽을 사용
        final pMin = wf.getPixelMin(idx).toDouble().abs();
        final pMax = wf.getPixelMax(idx).toDouble().abs();
        final pAmp = math.max(pMin, pMax) / maxAbs;
        if (pAmp > peak) peak = pAmp;
      }
      // 최소 바닥을 조금 올려 미세구간이 0으로 눕지 않게
      peaks.add(peak.clamp(0.02, 1.0));
      i += step;
    }
    return peaks;
  }

  // ---- (옵션) 디버그: 캐시 옆에 프리뷰 저장 ----
  Future<void> savePreviewJson({
    required String cacheDir,
    required String cacheKey,
    required List<double> peaks,
  }) async {
    final f = File(p.join(cacheDir, '$cacheKey.wfm.json'));
    try {
      await f.writeAsString(jsonEncode(peaks), flush: true);
    } catch (_) {
      /* ignore */
    }
  }
}
