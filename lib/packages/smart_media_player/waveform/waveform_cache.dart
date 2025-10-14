// lib/packages/smart_media_player/waveform/waveform_cache.dart
// v1.98.0 | Stereo-ready API + Energy peaks + safe fallback
//
// - loadOrBuild() : 기존 단일 리스트(모노) 유지
// - loadOrBuildStereo() : (left, right) 튜플 반환. 라이브러리가 채널 분리를
//   못 주면 모노를 좌/우 동일 값으로 반환(안전 폴백).
//
// - 트랜스크라이브 느낌: 구간 '최댓값' 대신 평균 진폭(에너지 근사) 사용
//   + 소량 EMA 평활화 -> 꽉 찬 직사각형 문제 방지, 미세 다이내믹 표현
//
// - 모든 미디어 경로(영상 포함)에서 JustWaveform.extract 시도.
//   디코더가 영상 컨테이너를 지원하지 않는 경우엔 플러그인/코덱 설치가 필요할 수 있음.

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

  // ------- 기존 모노 API (호환 유지) -------
  Future<List<double>> loadOrBuild({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int targetBars = 1600,
    WaveformProgressCallback? onProgress,
  }) async {
    final wf = await _ensureWaveform(mediaPath, cacheDir, cacheKey, onProgress);
    return _energyPeaksMono(wf, targetBars: targetBars);
  }

  // ------- 신규: 스테레오 API -------
  Future<(List<double> left, List<double> right)> loadOrBuildStereo({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int targetBars = 1600,
    WaveformProgressCallback? onProgress,
  }) async {
    final wf = await _ensureWaveform(mediaPath, cacheDir, cacheKey, onProgress);

    // NOTE: 현재 just_waveform이 채널별 min/max 접근을 표준 API로
    //       제공하지 않는 환경이 있을 수 있음.
    //       이런 경우 모노를 좌/우 동일로 반환(폴백).
    //
    //       추후 라이브러리가 채널별 픽셀 접근을 제공하면
    //       아래 _energyPeaksStereo()를 실제 채널 분리 계산으로 교체.

    final mono = _energyPeaksMono(wf, targetBars: targetBars);
    final left = List<double>.from(mono);
    final right = List<double>.from(mono);

    // L/R 정규화(형식상 — 현재는 동일 배열이므로 변화 없음)
    _normalizePair(left, right);

    return (left, right);
  }

  // ------- 공통: Waveform 확보 -------
  Future<Waveform> _ensureWaveform(
    String mediaPath,
    String cacheDir,
    String cacheKey,
    WaveformProgressCallback? onProgress,
  ) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final wavePath = p.join(cacheDir, '$cacheKey.wave');
    final waveFile = File(wavePath);

    if (await waveFile.exists()) {
      try {
        return await JustWaveform.parse(waveFile);
      } catch (_) {
        /* 재생성으로 폴백 */
      }
    }

    Waveform? lastWave;
    final stream = JustWaveform.extract(
      audioInFile: File(mediaPath),
      waveOutFile: waveFile,
    );
    final c = Completer<void>();
    stream.listen(
      (e) {
        onProgress?.call(e.progress);
        if (e.waveform != null) lastWave = e.waveform;
      },
      onError: (err) => c.completeError(err),
      onDone: () => c.complete(),
      cancelOnError: true,
    );
    await c.future;

    return lastWave ?? await JustWaveform.parse(waveFile);
  }

  // ------- 모노(에너지 기반) -------
  // v1.99.0 | transient-friendly hybrid peaks (max ⟂ rms), single dB/gamma
  List<double> _energyPeaksMono(Waveform wf, {int targetBars = 1600}) {
    final N = wf.length;
    if (N <= 0) return const [];
    final is16 = wf.flags == 0;
    final maxAbs = is16 ? 32768.0 : 128.0;

    targetBars = targetBars.clamp(1, math.max(1, N)); // ✅ 방어

    final out = <double>[];
    int produced = 0;
    int start = 0;

    while (produced < targetBars) {
      final targetEnd = ((N * (produced + 1)) / targetBars).floor();
      final end = targetEnd.clamp(start + 1, N);

      double sumSq = 0.0, maxAmp = 0.0;
      int cnt = 0;

      for (int idx = start; idx < end; idx++) {
        final pMin = wf.getPixelMin(idx).toDouble().abs();
        final pMax = wf.getPixelMax(idx).toDouble().abs();
        final amp = ((pMin + pMax) * 0.5) / maxAbs; // 0..1
        if (amp > maxAmp) maxAmp = amp;
        sumSq += amp * amp;
        cnt++;
      }

      double rms = (cnt > 0) ? math.sqrt(sumSq / cnt) : 0.0;
      double hybrid = (maxAmp * 0.7 + rms * 0.3);

      // -60dB 컷
      double norm;
      if (hybrid <= 0.0) {
        norm = 0.0;
      } else {
        const eps = 1e-9;
        final db = 20 * math.log(hybrid + eps) / math.ln10; // 0..-∞
        norm = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
        norm = math.pow(norm, 1.6).toDouble(); // 감마
      }

      out.add(norm);

      start = end;
      produced++;
      if (start >= N) break;
    }

    while (out.length < targetBars) out.add(0.0); // 길이 보정
    return out;
  }



  // ------- (준비) 스테레오 정규화 -------
  void _normalizePair(List<double> L, List<double> R) {
    double maxL = 0, maxR = 0;
    for (final v in L) if (v > maxL) maxL = v;
    for (final v in R) if (v > maxR) maxR = v;
    if (maxL <= 0 || maxR <= 0) return;
    final scaleL = 1.0 / maxL;
    final scaleR = 1.0 / maxR;
    for (var i = 0; i < L.length; i++) {
      L[i] = (L[i] * scaleL).clamp(0.0, 1.0);
      R[i] = i < R.length ? (R[i] * scaleR).clamp(0.0, 1.0) : 0.0;
    }
  }

  // ------- (옵션) 미리보기 저장 -------
  Future<void> savePreviewJson({
    required String cacheDir,
    required String cacheKey,
    required List<double> peaks,
  }) async {
    final f = File(p.join(cacheDir, '$cacheKey.wfm.json'));
    try {
      await f.writeAsString(jsonEncode(peaks), flush: true);
    } catch (_) {}
  }
}
