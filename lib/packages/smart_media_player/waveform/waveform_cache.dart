// lib/packages/smart_media_player/waveform/waveform_cache.dart
// v3.31.6 | JustWaveform 캐시/로딩 안정화 + 형변환/널가드

import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;

import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;

typedef WaveformProgressCallback = void Function(double p);

class WaveformLoadResult {
  final List<double> rmsL; // 0..1
  final List<double> rmsR; // 0..1
  const WaveformLoadResult({required this.rmsL, required this.rmsR});
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

    // 0) 입력/디렉토리 방어
    final inFile = File(mediaPath);
    if (!await inFile.exists()) {
      onProgress?.call(1.0);
      throw FileSystemException('오디오 파일을 찾을 수 없습니다', mediaPath);
    }
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 1) JustWaveform: Stream<WaveformProgress> 순회
    final tmpWavPath = p.join(cacheDir, '$cacheKey.jw.cache');
    final tmpFile = File(tmpWavPath);
    try {
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    } catch (_) {}

    Waveform? wf;
    try {
      final progressStream = JustWaveform.extract(
        audioInFile: inFile,
        waveOutFile: tmpFile,
      );

      await for (final e in progressStream) {
        onProgress?.call((e.progress).clamp(0.0, 1.0));
        if (e.waveform != null) {
          wf = e.waveform!;
        }
      }
    } catch (e, st) {
      dev.log('[CACHE] extract error: $e', stackTrace: st);
      onProgress?.call(1.0);
      rethrow;
    }

    if (wf == null) {
      onProgress?.call(1.0);
      throw StateError(
        'JustWaveform.extract()가 Waveform을 생성하지 못했습니다: $mediaPath',
      );
    }

    // 여기부터는 널 아님
    final List<int> data = wf.data;
    final int n = data.length;

    // 목표 샘플 수/윈도우 계산
    final int ts = (targetSamples ?? math.min(60000, n)).clamp(512, 120000);
    final int hop = (n / ts).ceil().clamp(1, n);
    final int win = hop;

    // 정규화 계수 (double)
    double maxAbs = 0.0;
    for (int i = 0; i < n; i++) {
      final double v = data[i].toDouble().abs();
      if (v > maxAbs) maxAbs = v;
    }
    if (maxAbs <= 0) maxAbs = 1.0;

    List<double> rmsSeq() {
      final out = <double>[];
      for (int i = 0; i + win <= n; i += hop) {
        double acc = 0.0;
        for (int k = 0; k < win; k++) {
          final double v = (data[i + k].toDouble() / maxAbs);
          acc += v * v;
        }
        out.add(math.sqrt(acc / win));
      }
      if (out.isEmpty) out.add(0.0);
      return out;
    }

    final rms = rmsSeq();
    final rmsL = rms;
    final rmsR = List<double>.from(rms);

    onProgress?.call(1.0);
    sw.stop();
    dev.log('[CACHE] done in ${sw.elapsedMilliseconds}ms, rms=${rmsL.length}');
    return WaveformLoadResult(rmsL: rmsL, rmsR: rmsR);
  }
}
