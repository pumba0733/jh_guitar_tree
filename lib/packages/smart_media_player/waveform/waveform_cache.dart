// lib/packages/smart_media_player/waveform/waveform_cache.dart
//
// v3.12.0 | Stereo+Signed Waveform Pipeline (Unified)
// - NEW: __ensureStereoWavs() — FFmpeg 단일 경로로 L/R 추출(44100 s16le), 실패 시 모노 폴백
// - NEW: loadOrBuildStereoSigned() — L/R 부호(±) 유지 샘플, 보기 스케일은 WaveformTuning.signedVisualScale 사용
// - KEEP: LOD(저/중/고) 생성 경로 유지, 모노 API 하위호환
// - SAFE: 캐시 파일(.wave) 손상 시 자동 재추출
//
// Optional deps at runtime: ffmpeg (CLI) — 미설치 시 자동 모노 fallback

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;

// Local
import './waveform_tuning.dart';
// FFTW Analyzer / LOD (상대 경로로 통일)
import 'analyzer/waveform_analyzer_fftw.dart'
    show WaveformAnalyzerFftw, WaveformAnalyzerFftwOptions, BandEnergySeries;

import './lod/waveform_lod_builder.dart';


typedef WaveformProgressCallback = void Function(double percent);

class WaveformLevels {
  final List<double> low;
  final List<double> mid;
  final List<double> high;
  const WaveformLevels(this.low, this.mid, this.high);
}

class WaveformCache {
  WaveformCache._();
  static final instance = WaveformCache._();

  // in-memory waveform cache (key = cacheDir/cacheKey)
  final Map<String, Waveform> _wfMem = {};
  String _key(String cacheDir, String cacheKey) => '$cacheDir::$cacheKey';

  // ===== FFTW 파이프라인 버전 태그 =====

  

  // ===== Public APIs =====

  // ------- 기존 모노 API (호환 유지) -------
  Future<List<double>> loadOrBuild({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int? targetBars,
    Duration? durationHint,
    WaveformProgressCallback? onProgress,
  }) async {
    final wf = await _ensureWaveform(mediaPath, cacheDir, cacheKey, onProgress);
    final tb =
        targetBars ?? _autoTargetBars(wf.length, durationHint: durationHint);
    return _buildMonoPeaks(wf, tb);
  }

  // ------- LOD 3단계 (옵션 사용) -------
  Future<WaveformLevels> loadOrBuildLevels({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    Duration? durationHint,
    WaveformProgressCallback? onProgress,
  }) async {
    final wf = await _ensureWaveform(mediaPath, cacheDir, cacheKey, onProgress);
    final highBars = _autoTargetBars(wf.length, durationHint: durationHint);
    final midBars = (highBars / 4).clamp(2048, highBars).toInt();
    final lowBars = (highBars / 16).clamp(1024, midBars).toInt();

    final high = _buildMonoPeaks(wf, highBars);
    final mid = _downsample(high, high.length, midBars);
    final low = _downsample(high, high.length, lowBars);
    return WaveformLevels(low, mid, high);
  }

  // ------- NEW: 스테레오 + 부호(±) 샘플 -------
  // 반환: (-1..+1) 범위의 서명 샘플(시각화용, dB/오토게인 적용 전 원시값 기반)
  Future<(List<double> left, List<double> right)> loadOrBuildStereoSigned({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int? targetSamples,
    Duration? durationHint,
    WaveformProgressCallback? onProgress,
  }) async {
    // 1) FFmpeg로 L/R mono wav 분리 시도 — 단일 경로로 통일
    final split = await __ensureStereoWavs(
  mediaPath: mediaPath,
  cacheDir: cacheDir,
  cacheKey: cacheKey,
);

// __ensureStereoWavs 한 경로로 통일 + File 전달
final wfL = await _ensureWaveformFromFile(
  split.left, // File
  cacheDir,
  '${cacheKey}_L',
  onProgress,
);
final wfR = await _ensureWaveformFromFile(
  split.right, // File
  cacheDir,
  '${cacheKey}_R',
  onProgress,
);




    final tb =
        targetSamples ?? _autoTargetBars(wfL.length, durationHint: durationHint);

    final left = _buildSignedSamples(wfL, tb);
    final right = _buildSignedSamples(wfR, tb);

    // 좌/우 공통 스케일 정규화(절댓값 기준) 후, 보기 스케일 보정은 튜닝에서
    _normalizePairAbsShared(left, right);
    final visScale = WaveformTuning.I.signedVisualScale.clamp(0.5, 1.0);
    for (int i = 0; i < left.length; i++) {
      left[i] = (left[i] * visScale).clamp(-1.0, 1.0);
      if (i < right.length) {
        right[i] = (right[i] * visScale).clamp(-1.0, 1.0);
      }
    }

    debugPrint('[WAVE] stereoSigned done L=${left.length} R=${right.length}');
    return (left, right);
  }

  // ------- 스테레오 API (절댓값 피크; 기존 painter 호환) -------
  Future<(List<double> left, List<double> right)> loadOrBuildStereo({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    int? targetBars,
    Duration? durationHint,
    WaveformProgressCallback? onProgress,
  }) async {
    final split = await __ensureStereoWavs(
  mediaPath: mediaPath,
  cacheDir: cacheDir,
  cacheKey: cacheKey,
);

final wfL = await _ensureWaveformFromFile(
  split.left, // File
  cacheDir,
  '${cacheKey}_L',
  onProgress,
);
final wfR = await _ensureWaveformFromFile(
  split.right, // File
  cacheDir,
  '${cacheKey}_R',
  onProgress,
);




    final tb =
        targetBars ?? _autoTargetBars(wfL.length, durationHint: durationHint);

    final leftSigned = _buildSignedSamples(wfL, tb);  // -1..+1
    final rightSigned = _buildSignedSamples(wfR, tb);

    final leftAbs = leftSigned.map((v) => v.abs()).toList(growable: false);
    final rightAbs = rightSigned.map((v) => v.abs()).toList(growable: false);

    _normalizePairAbsShared(leftAbs, rightAbs);
    return (leftAbs, rightAbs);
  }

  // 내부 Waveform 직접 접근
  Future<Waveform> getWaveform({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    WaveformProgressCallback? onProgress,
  }) async {
    return _ensureWaveform(mediaPath, cacheDir, cacheKey, onProgress);
  }

  // ------- NEW: FFTW 대역 에너지 기반 LOD 생성 -------
  Future<WaveformLevels> loadOrBuildLodFftw({
    required String mediaPath,
    required String cacheDir,
    required String cacheKey,
    Duration? durationHint,
    WaveformAnalyzerFftwOptions options = const WaveformAnalyzerFftwOptions(),
    WaveformProgressCallback? onProgress,
  }) async {
    debugPrint(
      '[FFTW] LOD analyze start path=$mediaPath '
      'opts=fft:${options.fftSize} hop:${options.hopSize} '
      'bands:${options.bands} aw:${options.aWeighting}',
    );

    // 1) L/R wav 확보 — 실패시 모노 폴백(양 채널 동일)
    final split = await __ensureStereoWavs(
      mediaPath: mediaPath,
      cacheDir: cacheDir,
      cacheKey: cacheKey,
    );

    // 2) PCM16LE mono 읽어 Float32로 변환
    
    final leftF32  = await _readWavPcm16leMonoAsFloat32(split.left);
    final rightF32 = await _readWavPcm16leMonoAsFloat32(split.right);

    

    // 3) Analyzer(FFTW) 실행
    final analyzer = WaveformAnalyzerFftw();
    final bands = await analyzer.analyzeFloat32Stereo(
      left: leftF32,
      right: rightF32,
      sampleRate: 44100, // __ensureStereoWavs에서 44.1k로 강제 추출
      options: options,
    );

    // 4) LOD 빌더
    final lodBuilder = WaveformLodBuilder();
    final lod = lodBuilder.buildFromBands(bands);
    debugPrint('[FFTW] LOD built low=${lod.lowL.length} '
             'mid=${lod.midL.length} high=${lod.highL.length}');
    return WaveformLevels(
      lod.lowL.isEmpty ? const [] : lod.lowL,
      lod.midL.isEmpty ? const [] : lod.midL,
      lod.highL.isEmpty ? const [] : lod.highL,
    );
  }

  // ===== Internal =====

  int _autoTargetBars(int length, {Duration? durationHint}) {
    if (durationHint == null || durationHint <= Duration.zero) {
      return length.clamp(8192, 300000);
    }
    final seconds = durationHint.inMilliseconds / 1000.0;
    final sec = seconds;
    int est;
    if (sec <= 90) {
      est = (sec * 44100 / 512).round();   // 짧은 파일: 촘촘
    } else if (sec <= 8 * 60) {
      est = (sec * 44100 / 1024).round();  // 8분 이내: 기본
    } else {
      est = (sec * 44100 / 2048).round();  // 아주 긴 파일: 느슨
    }
    return est.clamp(8192, 300000);
  }

  Future<Waveform> _ensureWaveform(
    String mediaPath,
    String cacheDir,
    String cacheKey,
    WaveformProgressCallback? onProgress,
  ) async {
    final key = _key(cacheDir, cacheKey);
    final cached = _wfMem[key];
    if (cached != null) return cached;

    final dir = Directory(cacheDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final wavePath = p.join(cacheDir, '$cacheKey.wave');
    final waveFile = File(wavePath);

    Waveform wf;
    if (await waveFile.exists()) {
      try {
        wf = await JustWaveform.parse(waveFile);
      } catch (_) {
        wf = await _extractSingle(mediaPath, waveFile, onProgress);
      }
    } else {
      wf = await _extractSingle(mediaPath, waveFile, onProgress);
    }

    _wfMem[key] = wf;
    return wf;
  }




  Future<Waveform> _ensureWaveformFromFile(
    File audioFile, // wav or any supported
    String cacheDir,
    String cacheKey,
    WaveformProgressCallback? onProgress,
  ) async {
    final key = _key(cacheDir, cacheKey);
    final cached = _wfMem[key];
    if (cached != null) return cached;

    final dir = Directory(cacheDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final wavePath = p.join(cacheDir, '$cacheKey.wave');
    final waveFile = File(wavePath);

    Waveform wf;
    if (await waveFile.exists()) {
      try {
        wf = await JustWaveform.parse(waveFile);
      } catch (_) {
        wf = await _extractSingle(audioFile.path, waveFile, onProgress);
      }
    } else {
      wf = await _extractSingle(audioFile.path, waveFile, onProgress);
    }

    _wfMem[key] = wf;
    return wf;
    
  }

  Future<Waveform> _extractSingle(
    String mediaPath,
    File waveFile,
    WaveformProgressCallback? onProgress,
  ) async {
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

  // ===== WAV(PCM16LE, mono) → Float32 변환 =====
  Future<List<double>> _readWavPcm16leMonoAsFloat32(File wav) async {
    // __ensureStereoWavs()에서 '-ac 1 -ar 44100 -acodec pcm_s16le' 출력 전제
    final bytes = await wav.readAsBytes();
    if (bytes.length < 44) return const []; // 최소 WAV 헤더
    final bd = bytes.buffer.asByteData();

    final int dataOffset = 44; // 단순 전제
    final int dataBytes = bytes.length - dataOffset;
    if (dataBytes <= 0) return const [];

    final int samples = dataBytes ~/ 2; // 16bit
    final out = List<double>.filled(samples, 0.0, growable: false);

    int o = dataOffset;
    for (int i = 0; i < samples; i++, o += 2) {
      final int16 = bd.getInt16(o, Endian.little);
      out[i] = (int16 / 32768.0).clamp(-1.0, 1.0);
    }
    return out;
  }

  // ===== FFmpeg 기반 스테레오 분리 (단일 경로) =====
  Future<bool> _hasFfmpeg() async {
    try {
      final r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // 통일된 스테레오 분리 + 캐시
  Future<({File left, File right})> __ensureStereoWavs({
  required String mediaPath,
  required String cacheDir,
  required String cacheKey,
}) async {
  final chDir = Directory(p.join(cacheDir, '${cacheKey}_ch'));
  if (!await chDir.exists()) await chDir.create(recursive: true);

  final wavL = File(p.join(chDir.path, 'L.wav'));
  final wavR = File(p.join(chDir.path, 'R.wav'));

  if (await wavL.exists() && await wavR.exists()) {
    return (left: wavL, right: wavR);
  }

  if (await _hasFfmpeg()) {
    Future<void> extractSide(String chan, File outFile) async {
      final args = [
        '-y', '-i', mediaPath,
        '-vn',
        '-acodec', 'pcm_s16le',
        '-ar', '44100',
        '-ac', '1',
        '-af', 'pan=1c|c0=$chan', // FL or FR
        outFile.path,
      ];
      final r = await Process.run('ffmpeg', args);
      if (r.exitCode != 0) {
        throw Exception('ffmpeg extract($chan) failed: ${r.stderr}');
      }
    }

    try {
      await extractSide('FL', wavL);
      await extractSide('FR', wavR);
      return (left: wavL, right: wavR);
    } catch (e) {
      debugPrint('[WAVE] ffmpeg failed, fallback to mono. $e');
    }
  } else {
    debugPrint('[WAVE] ffmpeg not found, fallback to mono.');
  }

  final mono = File(mediaPath);
  return (left: mono, right: mono);
}


  // ===== Builders =====

  // 시청용(0..1) 모노 하이브리드 peak
  List<double> _buildMonoPeaks(Waveform wf, int targetBars) {
    final N = wf.length;
    if (N <= 0) return const [];
    targetBars = targetBars.clamp(1, math.max(1, N));

    final is16 = wf.flags == 0;
    final maxAbs = is16 ? 32768.0 : 128.0;

    final out = List<double>.filled(targetBars, 0.0, growable: false);
    int start = 0;

    for (int produced = 0; produced < targetBars; produced++) {
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

      final rms = (cnt > 0) ? math.sqrt(sumSq / cnt) : 0.0;
      final hybrid = (maxAmp * 0.6 + rms * 0.4);
      out[produced] = _dbMapped(hybrid);

      start = end;
      if (start >= N) break;
    }
    return out;
  }

  // 부호(±) 보존 샘플 빌더 (-1..+1)
  List<double> _buildSignedSamples(Waveform wf, int targetSamples) {
    final N = wf.length;
    if (N <= 0) return const [];
    targetSamples = targetSamples.clamp(1, math.max(1, N));

    final is16 = wf.flags == 0;
    final maxAbs = is16 ? 32768.0 : 128.0;

    final out = List<double>.filled(targetSamples, 0.0, growable: false);
    int start = 0;

    for (int i = 0; i < targetSamples; i++) {
      final targetEnd = ((N * (i + 1)) / targetSamples).floor();
      final end = targetEnd.clamp(start + 1, N);

      double maxV = -double.infinity;
      double minV = double.infinity;

      for (int idx = start; idx < end; idx++) {
        final vMin = wf.getPixelMin(idx).toDouble();
        final vMax = wf.getPixelMax(idx).toDouble();
        if (vMax > maxV) maxV = vMax;
        if (vMin < minV) minV = vMin;
      }

      final absMax = maxV.abs();
      final absMin = minV.abs();
      final sign = (absMax >= absMin) ? 1.0 : -1.0;
      final peakAbs = (absMax >= absMin) ? absMax : absMin;

      out[i] = (sign * (peakAbs / maxAbs)).clamp(-1.0, 1.0);
      start = end;
      if (start >= N) break;
    }
    return out;
  }

  double _dbMapped(double amp) {
    return WaveformTuning.I.dbMapped(amp);
  }

  List<double> _downsample(List<double> src, int n, int target) {
    final out = List<double>.filled(target, 0.0, growable: false);
    int start = 0;
    for (int i = 0; i < target; i++) {
      final end = (((i + 1) * n) / target).floor().clamp(start + 1, n);
      double s = 0.0;
      int c = 0;
      for (int k = start; k < end; k++) {
        s += src[k];
        c++;
      }
      out[i] = c > 0 ? (s / c) : 0.0;
      start = end;
    }
    return out;
  }

  // 둘 중 더 큰 절댓값을 기준으로 "공통 스케일" 적용 → 좌/우 밸런스 보존
  void _normalizePairAbsShared(List<double> L, List<double> R) {
    double maxAbs = 0.0;
    for (final v in L) {
      final a = v.abs();
      if (a > maxAbs) maxAbs = a;
    }
    for (final v in R) {
      final a = v.abs();
      if (a > maxAbs) maxAbs = a;
    }
    if (maxAbs <= 0) return;
    final s = 1.0 / maxAbs;
    for (var i = 0; i < L.length; i++) {
      L[i] = (L[i] * s).clamp(-1.0, 1.0);
      if (i < R.length) R[i] = (R[i] * s).clamp(-1.0, 1.0);
    }
  }

  // (옵션) 미리보기 저장
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
