// lib/packages/smart_media_player/waveform/waveform_cache.dart
// v1.85.1 | Degraded Waveform Cache (deterministic fake peaks)
// - 실제 오디오 분석 없이 mediaHash 기반 의사파형 생성
// - 파일: <cacheDir>/<hash>.wfm.json
// - 추후 just_waveform 실추출로 교체 예정

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

typedef WaveformProgress = void Function(double percent);

class WaveformCache {
  WaveformCache._();
  static final instance = WaveformCache._();

  Future<List<double>> loadOrBuildDegraded({
    required String cacheDir,
    required String cacheKey,
    int bars = 800,
    WaveformProgress? onProgress,
  }) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$cacheKey.wfm.json');

    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString());
        if (j is List) {
          return j.map((e) => (e as num).toDouble()).toList(growable: false);
        }
      } catch (_) {
        /* ignore */
      }
    }

    // 결정론 PRNG (cacheKey 해시 기반 시드)
    final seed = cacheKey.codeUnits.fold<int>(
      0,
      (a, b) => (a * 131 + b) & 0x7fffffff,
    );
    final rnd = math.Random(seed);

    final peaks = <double>[];
    for (var i = 0; i < bars; i++) {
      // 베이스: 완만한 사인 + 랜덤 노이즈
      final t = i / bars;
      final base =
          0.5 +
          0.45 * math.sin(2 * math.pi * (t * (1.0 + 0.2 * math.sin(t * 6))));
      final noise = (rnd.nextDouble() - 0.5) * 0.15;
      var v = (base + noise).clamp(0.05, 0.98);
      // 약간의 리듬성 강조
      if (i % 32 == 0) v = (v + 0.15).clamp(0.05, 0.98);
      peaks.add(v);
      if (onProgress != null && i % 40 == 0) {
        onProgress(i / bars);
      }
    }

    try {
      await file.writeAsString(jsonEncode(peaks), flush: true);
    } catch (_) {
      /* ignore */
    }

    onProgress?.call(1.0);
    return peaks;
  }
}
