// lib/packages/smart_media_player/engine/engine_api.dart
//
// SmartMediaPlayer v3.8-FF — STEP 4 + Step 3-P2/P3 StartCue/Loop/Space/FFRW 통합
// EngineApi = FFmpeg 네이티브 엔진 thin wrapper + mpv(video-only)
//
// 책임:
//  - 파일 로드(FFmpeg 네이티브 엔진 openFile)
//  - play/pause/seekUnified
//  - tempo/pitch/volume (네이티브 엔진)
//  - spaceBehavior / playFromStartCue / loopExitToStartCue
//  - unified seek (audio master, video slave)
//  - video sync 보조 (VideoSyncService에 pending target 제공)
//  - position/duration stream (FFmpeg SoT 기반)
//  - FFRW (seek 기반 시뮬레이션)
//
// 제약:
//  - 오디오는 100% 네이티브 엔진이 담당 (FFmpeg + SoundTouch + miniaudio)
//  - media_kit Player는 영상 렌더링 및 완료 이벤트 전용
//

import '../../smart_media_player/video/sticky_video_overlay.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../audio/engine_soundtouch_ffi.dart';
import '../video/video_sync_service.dart';

// ================================================================
// SoT / Playback QA 로깅 헬퍼
// ================================================================

// ✅ 기본 이벤트(로드/플레이/일시정지/시크 등) 로그
const bool kSmpEngineLogBasic = true;

// ✅ SoT tick / FFRW tick 같이 "자주 찍히는 로그" 전용 스위치
//   → 평소에는 false로 두고, QA 땐 true로 올려서 쓰면 됨.
const bool kSmpEngineLogTick = false;

void _logSmpEngine(String message, {bool tick = false}) {
  if (tick) {
    if (!kSmpEngineLogTick) return;
  } else {
    if (!kSmpEngineLogBasic) return;
  }
  debugPrint('[SMP/EngineApi] $message');
}

class EngineApi {
  EngineApi._();
  static final EngineApi instance = EngineApi._();

  // ================================================================
  // CORE FIELDS
  // ================================================================
  final Player _player = Player(); // video 전용
  bool _initialized = false;
  bool _hasFile = false;

  Duration _duration = Duration.zero;

  /// StartCue의 단일 소스 (Screen 상태에서 주입)
  /// - Screen 쪽에서 `EngineApi.instance.startCueProvider = () => _startCue;`
  ///   형태로 설정한다.
  Duration Function()? startCueProvider;

  // 네이티브 엔진 재생 상태(오디오 기준)
  bool _nativePlaying = false;

  // SEEK LOCKING SYSTEM
  bool _seeking = false; // seekUnified() 실행 중 보호 플래그

  // VideoSyncService에서 소비하는 단일 pending 타겟
  Duration? _pendingVideoTarget;

  // Streams
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();

  Stream<Duration> get position$ => _positionCtl.stream;
  Stream<Duration> get duration$ => _durationCtl.stream;
  Stream<bool> get playing$ => _playingCtl.stream;

  // FFmpeg SoT polling용 타이머
  Timer? _positionTimer;
  DateTime? _lastPosLogAt;

  // 🔥 오디오(FFmpeg SoT) 기준 트랙 종료 감지용 상태
  Duration? _lastPolledPosition;
  bool _endCandidate = false;

  // ================================================================
  // PUBLIC GETTERS
  // ================================================================
  Player get player => _player; // UI read-only (video 전용)

  Duration get duration => _duration;

  /// FFmpeg SoT 기반 현재 위치 (항상 [0, duration] 범위로 클램프)
  Duration get position {
    if (!_hasFile || _duration <= Duration.zero) return Duration.zero;
    final raw = stGetPosition();
    final pos = _clampToDuration(raw);
    return pos;
  }

  bool get isPlaying => _nativePlaying;

  // VideoSyncService bridge
  bool get hasVideo => VideoSyncService.instance.isVideoLoaded;
  Duration get videoPosition => VideoSyncService.instance.videoPosition;
  VideoController? get videoController => VideoSyncService.instance.controller;

  // VideoSyncService Phase E: 단일 pendingVideoTarget 채널
  Duration? get pendingVideoTarget => _pendingVideoTarget;
  set pendingVideoTarget(Duration? v) => _pendingVideoTarget = v;

  // 🔁 기존 이름과의 호환용(다른 파일에서 참조 중일 수 있으므로 남겨둠)
  @Deprecated('Use pendingVideoTarget instead')
  Duration? get pendingSeekTarget => _pendingVideoTarget;
  @Deprecated('Use pendingVideoTarget instead')
  set pendingSeekTarget(Duration? v) => _pendingVideoTarget = v;

  @Deprecated('pendingAlignTarget merged into pendingVideoTarget')
  Duration? get pendingAlignTarget => _pendingVideoTarget;
  @Deprecated('pendingAlignTarget merged into pendingVideoTarget')
  set pendingAlignTarget(Duration? v) => _pendingVideoTarget = v;

  // ================================================================
  // INTERNAL HELPERS (P2/P3: StartCue/Loop = “범위 정보”, seek = “자유 시킹”)
  // ================================================================

  /// 비디오를 오디오 seek 타겟에 강제로 맞추고 싶을 때 사용하는 채널.
  /// - EngineApi에서는 "목표 등록"만 하고
  /// - 실제 mpv.seek는 VideoSyncService._tick()에서만 수행한다.
  void _scheduleVideoSeek(Duration target) {
    _pendingVideoTarget = target;
  }

  /// 유효 Loop 여부 판단(엔진 기준 글로벌 타임라인 클램프 후 A < B인지 확인)
  bool _hasValidLoop(Duration? loopA, Duration? loopB) {
    if (loopA == null || loopB == null) return false;
    if (_duration <= Duration.zero) return false;
    final a = _clampToDuration(loopA);
    final b = _clampToDuration(loopB);
    return a < b;
  }

  /// P2/P3: StartCue는 오직 [0, duration]만 기준으로 정규화한다.
  /// - LoopA/B는 하한/상한으로 개입하지 않는다.
  /// - duration이 아직 0이면 음수만 0으로 막고 그대로 돌려준다.
  Duration _normalizeStartCueValue(
    Duration sc, {
    Duration? loopA, // 시그니처 유지용 (현재는 무시)
    Duration? loopB, // 시그니처 유지용 (현재는 무시)
  }) {
    if (_duration <= Duration.zero) {
      return sc < Duration.zero ? Duration.zero : sc;
    }
    return _clampToDuration(sc);
  }

  /// P2/P3: seek 타겟은 항상 duration 기준 글로벌 클램프만 적용한다.
  /// - StartCue/Loop는 “범위 정보”로만 존재하고, 실제 시킹 경로에는 개입하지 않는다.
  Duration _normalizeTargetForSeek(
    Duration target, {
    Duration? loopA, // 현재 무시
    Duration? loopB, // 현재 무시
    Duration? startCue, // 현재 무시
  }) {
    return _clampToDuration(target);
  }

    // 🔥 오디오(SoT) 기준 트랙 종료 처리 공통 루틴
  Future<void> _handleTrackCompleted() async {
    try {
      // StartCue를 항상 Screen 상태에서 가져온다.
      final raw = startCueProvider?.call() ?? Duration.zero;
      final cue = _normalizeStartCueValue(raw);

      _logSmpEngine(
        'trackCompleted: seek back to StartCue=${cue.inMilliseconds}ms '
        '(raw=${raw.inMilliseconds}ms) and auto play',
      );

      // StartCue 정보를 같이 넘겨서 엔진 내부 normalize 규칙과도 일치시킨다.
      await seekUnified(cue, startCue: cue);

      // ✅ P3 규칙: Loop OFF + 트랙 끝 → StartCue에서 자동 재생 유지
      await play();
    } catch (e) {
      debugPrint('[EngineApi] track-completed error: $e');
    }
  }

  // ================================================================
  // INIT
  // ================================================================
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    MediaKit.ensureInitialized();
    stInitEngine();
    _logSmpEngine('init(): engine initialized');

    // FFmpeg SoT polling (position stream)
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_hasFile) return;

      final raw = stGetPosition();
      final pos = (_duration > Duration.zero)
          ? _clampToDuration(raw)
          : raw; // duration 미정일 때는 raw 그대로

      // === 기본 position 스트림 전파 ===
      _positionCtl.add(pos);

      // === 오디오(SoT) 기반 트랙 종료 감지 ===
      if (_duration > Duration.zero) {
        // "끝 근처" 영역 (마지막 80ms)
        final endThreshold = _duration - const Duration(milliseconds: 80);
        final wasAtEnd =
            _lastPolledPosition != null && _lastPolledPosition! >= endThreshold;
        final isAtEnd = pos >= endThreshold;

        // 끝 영역에 진입 → "후보" 플래그
        if (!wasAtEnd && isAtEnd) {
          _endCandidate = true;
        }

        // 후보 상태에서 위치가 더 이상 안 움직이고(정지) 오디오는 재생 중이면 → 실제 종료로 간주
        if (_endCandidate &&
            _lastPolledPosition != null &&
            pos == _lastPolledPosition &&
            _nativePlaying) {
          _endCandidate = false;
          unawaited(_handleTrackCompleted());
        }
      }

      _lastPolledPosition = pos;

      // SoT 로깅 (500ms 이상 간격으로만 + tick 채널에만)
      final now = DateTime.now();
      if (_lastPosLogAt == null ||
          now.difference(_lastPosLogAt!) >= const Duration(milliseconds: 500)) {
        _lastPosLogAt = now;
        _logSmpEngine(
          'tick: pos=${pos.inMilliseconds}ms, dur=${_duration.inMilliseconds}ms, playing=$_nativePlaying',
          tick: true,
        );
      }
    });

    // media_kit playing stream → playing$ (영상 상태와 오디오 상태를 최대한 맞춰준다)
    _player.stream.playing.listen((v) {
      // 오디오는 _nativePlaying 기준이지만, UI 호환성을 위해
      // 비디오 재생 상태도 함께 반영한다.
      final combined = _nativePlaying || v;
      _playingCtl.add(combined);
      _logSmpEngine('player.stream.playing: mpvPlaying=$v, combined=$combined');
    });

    // 🔁 영상 완료 이벤트는 "오디오 마스터" 원칙상 트랙 종료 로직을 직접 건드리지 않는다.
    _player.stream.completed.listen((_) {
      _logSmpEngine('player.stream.completed: video completed (audio=master)');
    });
  }

  // ================================================================
  // LOAD MEDIA (FFmpeg 네이티브 엔진 + optional video)
  // ================================================================
  Future<Duration> load({
    required String path,
    required void Function(Duration) onDuration,
  }) async {
    await init();

    final f = File(path);
    if (!await f.exists()) {
      throw Exception('[EngineApi] File not found: $path');
    }

    _logSmpEngine('load(): path=$path');

    // 이전 파일 정리
    stCloseFile();
    _hasFile = false;
    _duration = Duration.zero;
    _pendingVideoTarget = null;
    _nativePlaying = false;
    _playingCtl.add(false);
    _lastPolledPosition = null;
    _endCandidate = false;

    // 네이티브 엔진에 파일 오픈
    final ok = stOpenFile(path);
    if (!ok) {
      throw Exception(
        '[EngineApi] Failed to open file via native engine: $path',
      );
    }
    _hasFile = true;

    // FFmpeg duration 확보
    _duration = stGetDuration();
    if (_duration < Duration.zero) {
      _duration = Duration.zero;
    }


    onDuration(_duration);
    _durationCtl.add(_duration);

    // === Video path (audio disabled, keep-open) ===
    final lower = path.toLowerCase();
    final isVideo =
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv');

    if (isVideo) {
      await _player.open(
        Media(path, extras: {'audio': 'no', 'keep-open': 'yes'}),
        play: false,
      );
      await VideoSyncService.instance.attachPlayer(_player);
    }

    // 오디오/비디오 모두 0으로 강제 align
    stSeekToDuration(Duration.zero);
    if (isVideo) {
      try {
        // 비디오는 VideoSyncService tick에서만 seek 수행
        _scheduleVideoSeek(Duration.zero);
      } catch (e) {
        debugPrint('[EngineApi] load() initial align scheduling error: $e');
      }
    }

    _positionCtl.add(Duration.zero);

    _logSmpEngine(
      'load(): duration=${_duration.inMilliseconds}ms, isVideo=$isVideo',
    );

    return _duration;
  }

  // ================================================================
  // PLAYBACK CONTROL (네이티브 엔진 + 비디오 연동)
  // ================================================================
  Future<void> play() async {
    final cur = position;
    _logSmpEngine(
      'play() requested at pos=${cur.inMilliseconds}ms, nativePlaying=$_nativePlaying',
    );

    // 🔒 이미 네이티브 엔진이 재생 중이면 절대 FFI 호출하지 않음
    if (_nativePlaying) {
      _logSmpEngine(
        'play(): nativePlaying already true, skip stPlay() / _player.play()',
      );
      return;
    }

    try {
      // 1) FFmpeg / SoundTouch 네이티브 엔진 재생 시작
      stPlay();
      _nativePlaying = true;
    } catch (e) {
      debugPrint('[EngineApi] play() stPlay error: $e');
    }

    try {
      // 2) 영상 플레이어(mpv) 재생 시작 (영상 없으면 예외 무시)
      await _player.play();
    } catch (_) {
      // 영상이 없으면 무시
    }

    // 3) 상위 레이어에 "지금은 재생 중"이라고 브로드캐스트
    _playingCtl.add(true);
    _logSmpEngine('play(): now nativePlaying=$_nativePlaying');
  }


  Future<void> pause() async {
    final cur = position;
    _logSmpEngine(
      'pause() requested at pos=${cur.inMilliseconds}ms, nativePlaying=$_nativePlaying',
    );

    // 네이티브 엔진에 pause 신호
    stPause();
    _nativePlaying = false;

    try {
      await _player.pause();
    } catch (_) {
      // 영상이 없으면 무시
    }

    _playingCtl.add(false);
    _logSmpEngine('pause(): now nativePlaying=$_nativePlaying');
  }

  Future<void> toggle() async {
    _logSmpEngine('toggle(): isPlaying=$isPlaying');
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  // ================================================================
  // Space Behavior
  //
  //  - 재생 중: pause()
  //  - 정지 상태: StartCue로 seek + play()
  //
  //  Loop ON/OFF, loopA/B 인자는 현재는 "참고 정보"로만 사용하고,
  //  실제 루프 동작은 LoopExecutor 쪽에서 처리한다.
  // ================================================================
  Future<void> spaceBehavior(
    Duration startCue, {
    Duration? loopA,
    Duration? loopB,
    bool loopOn = false,
  }) async {
    if (!_hasFile) return;

    final cur = position;
    final dur = _duration;

    _logSmpEngine(
      'spaceBehavior() called with '
      'sc=${startCue.inMilliseconds}ms, '
      'cur=${cur.inMilliseconds}ms, '
      'dur=${dur.inMilliseconds}, '
      'isPlaying=$_nativePlaying, '
      'loopOn=$loopOn',
    );

    // 🔺 재생 중 → pause
    if (_nativePlaying) {
      await pause();
      return;
    }

    final cue = _normalizeStartCueValue(startCue, loopA: loopA, loopB: loopB);

    await seekUnified(cue, loopA: loopA, loopB: loopB, startCue: cue);

    await play();
  }


  // ================================================================
  // LOOP EXIT → StartCue + Auto Play
  // ================================================================
  ///
  /// LoopExecutor 등에서 마지막 루프 종료 후 호출:
  ///  - StartCue로 seek
  ///  - 즉시 play() 유지 (Loop OFF + StartCue 재생 유지)
  Future<void> loopExitToStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    _logSmpEngine(
      'loopExitToStartCue(): sc=${sc.inMilliseconds}ms, '
      'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    // P2/P3: StartCue는 loop 범위와 무관하게 [0, duration] 기준 정규화
    Duration cue = _normalizeStartCueValue(sc, loopA: loopA, loopB: loopB);

    _logSmpEngine(
      'loopExitToStartCue(): normalized cue=${cue.inMilliseconds}ms',
    );


    await seekUnified(cue, loopA: loopA, loopB: loopB, startCue: cue);
    // ✅ 의도: 루프 종료 후 StartCue에서 바로 재생 유지
    await play();
  }

  // ================================================================
  // TEMPO / PITCH / VOLUME (네이티브 엔진 직접 호출)
  // ================================================================
  Future<void> setTempo(double v) async {
    final clamped = v.clamp(0.5, 1.5);
    _logSmpEngine('setTempo(): v=$v → clamped=$clamped');
    st_setTempo(clamped.toDouble());
  }

  Future<void> setPitch(int semi) async {
    final clamped = semi.clamp(-7, 7);
    _logSmpEngine('setPitch(): semi=$semi → clamped=$clamped');
    st_setPitch(clamped.toDouble());
  }

  Future<void> setVolume(double v01) async {
    final clamped = v01.clamp(0.0, 1.5);
    _logSmpEngine('setVolume(): v01=$v01 → clamped=$clamped');
    st_setVolume(clamped.toDouble());
  }

  Future<void> restoreChainState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    _logSmpEngine(
      'restoreChainState(): tempo=$tempo, pitchSemi=$pitchSemi, volume=$volume',
    );
    await setTempo(tempo);
    await setPitch(pitchSemi);
    await setVolume(volume);
  }

  Future<void> tempo(double v) async => setTempo(v);
  Future<void> pitch(int semi) async => setPitch(semi);
  Future<void> volume(double v01) async => setVolume(v01);

  Future<void> restoreState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    await restoreChainState(tempo: tempo, pitchSemi: pitchSemi, volume: volume);
  }

  // ================================================================
  // FAST-FORWARD / FAST-REVERSE (seek 기반 시뮬레이션)
  // ================================================================
  Timer? _ffrwTick;
  bool _ff = false;
  bool _fr = false;
  bool _ffStartedFromPause = false;
  bool _frStartedFromPause = false;

  static const Duration _ffrwInterval = Duration(milliseconds: 55);
  static const Duration _ffStep = Duration(milliseconds: 150);
  static const Duration _frStep = Duration(milliseconds: 150);

  Future<void> _startFfRwTick({
    required bool forward,
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _normalizeStartCueValue(
      startCue,
      loopA: loopA,
      loopB: loopB,
    );

    _logSmpEngine(
      '_startFfRwTick(): forward=$forward, startCue=${scNorm.inMilliseconds}ms, '
      'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    _ffrwTick?.cancel();

    _ff = forward;
    _fr = !forward;

    _ffrwTick = Timer.periodic(_ffrwInterval, (_) async {
      if (!_ff && !_fr) return;
      if (_seeking) return;

      final cur = position;
      Duration next;

      if (_ff) {
        next = cur + _ffStep;
      } else {
        next = cur - _frStep;
      }

      // P2/P3: FF/FR은 항상 “타임라인 자유 이동”
      // StartCue/Loop는 상하한으로 개입하지 않고,
      // duration 기반 글로벌 클램프만 적용
      next = _clampToDuration(next);

      if (_seeking) return;

      _logSmpEngine(
        'FFRW tick: forward=$_ff, cur=${cur.inMilliseconds}ms → next=${next.inMilliseconds}ms',
        tick: true,
      );

      await seekUnified(next);

      if (next == Duration.zero && _fr) {
        _logSmpEngine('FFRW tick: reached 0ms in FR → stop', tick: true);
        await fastReverse(false, startCue: scNorm);
      }
      if (next == _duration && _ff) {
        _logSmpEngine(
          'FFRW tick: reached end(${_duration.inMilliseconds}ms) in FF → stop',
          tick: true,
        );
        await fastForward(false, startCue: scNorm);
      }
    });
  }

  Future<void> fastForward(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _normalizeStartCueValue(
      startCue,
      loopA: loopA,
      loopB: loopB,
    );

    if (on) {
      _logSmpEngine(
        'fastForward(on): startCue=${scNorm.inMilliseconds}ms, '
        'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
      );

      if (_ff) return;

      final wasPlaying = isPlaying;
      _ffStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        _logSmpEngine('fastForward(on): wasPaused → seek to StartCue & play');
        await seekUnified(scNorm);
        await play();
      }

      _ff = true;
      _fr = false;

      await _startFfRwTick(
        forward: true,
        startCue: scNorm,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_ff) return;
    _ff = false;

    _logSmpEngine('fastForward(off): stop FFRW');

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_ffStartedFromPause) {
      _logSmpEngine('fastForward(off): returning to pause()');
      await pause();
    }

    _ffStartedFromPause = false;
  }

  Future<void> fastReverse(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _normalizeStartCueValue(
      startCue,
      loopA: loopA,
      loopB: loopB,
    );

    if (on) {
      _logSmpEngine(
        'fastReverse(on): startCue=${scNorm.inMilliseconds}ms, '
        'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
      );

      if (_fr) return;

      final wasPlaying = isPlaying;
      _frStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        _logSmpEngine('fastReverse(on): wasPaused → seek to StartCue & play');
        await seekUnified(scNorm);
        await play();
      }

      _fr = true;
      _ff = false;

      await _startFfRwTick(
        forward: false,
        startCue: scNorm,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_fr) return;
    _fr = false;

    _logSmpEngine('fastReverse(off): stop FFRW');

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_frStartedFromPause) {
      _logSmpEngine('fastReverse(off): returning to pause()');
      await pause();
    }

    _frStartedFromPause = false;
  }

  // ================================================================
  // UNIFIED SEEK (FFmpeg 네이티브 엔진 기준)
  // ================================================================
  Future<void> seekUnified(
    Duration d, {
    Duration? loopA,
    Duration? loopB,
    Duration? startCue,
  }) async {
    if (_seeking) {
      _logSmpEngine(
        'seekUnified(): already seeking, ignore new request d=${d.inMilliseconds}ms',
      );
      return;
    }

    if (_duration <= Duration.zero) {
      _logSmpEngine(
        'seekUnified(): duration is zero, ignore seek d=${d.inMilliseconds}ms',
      );
      return;
    }

    _seeking = true;

    final bool wasPlaying = isPlaying;

    // P2/P3: StartCue/Loop는 범위 정의 전용,
    //     실제 seek 타겟은 duration 기준 글로벌 클램프만 적용
    final int origTargetMs = d.inMilliseconds;
    Duration target = _normalizeTargetForSeek(
      d,
      loopA: loopA,
      loopB: loopB,
      startCue: startCue,
    );

    _logSmpEngine(
      'seekUnified(): d=${d.inMilliseconds}ms, origTarget=$origTargetMs ms, '
      'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}, '
      'startCue=${startCue?.inMilliseconds} → finalTarget=${target.inMilliseconds}ms, '
      'wasPlaying=$wasPlaying',
    );

    // 내부 상태 상 pos를 먼저 갱신 (SoT 기준)
    _positionCtl.add(target);

    try {
      // 1) FFmpeg 네이티브 엔진 seek (오디오 마스터)
      stSeekToDuration(target);

      // 2) VideoSyncService에 알리기 위한 pending target 설정
      _scheduleVideoSeek(target);
    } catch (e) {
      debugPrint('[EngineApi] seekUnified error: $e');
    } finally {
      _seeking = false;
    }

    if (wasPlaying) {
      // 🔒 재생 중이었는데, 이미 nativePlaying=true라면 추가 resume 금지
      if (!_nativePlaying) {
        _logSmpEngine('seekUnified(): resume play after seek');
        await play();
      } else {
        _logSmpEngine(
          'seekUnified(): already nativePlaying=true, skip resume play',
        );
      }
    } else {
      // 오디오는 정지 상태 유지, 영상도 정지 상태로 맞춰준다.
      try {
        await _player.pause();
      } catch (_) {}
      _logSmpEngine('seekUnified(): keep paused after seek');
    }
  }


  // ================================================================
  // PUBLIC FFRW FACADE & HELPERS
  // ================================================================
  FfRwFacade get ffrw => FfRwFacade(this);

  /// StartCue 버튼 전용:
  /// - Loop 여부와 상관없이 StartCue에서 바로 시작
  /// - Space 통합 규칙(loopOn에 따른 분기)와 독립적인 "강제 StartCue 재생"
  Future<void> playFromStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    Duration cue = _normalizeStartCueValue(sc, loopA: loopA, loopB: loopB);
    _logSmpEngine(
      'playFromStartCue(): sc=${sc.inMilliseconds}ms (norm=${cue.inMilliseconds}ms), '
      'loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    await seekUnified(cue, loopA: loopA, loopB: loopB, startCue: cue);
    await play();
  }

  // StickyVideoOverlay helper (Step 7까지 임시 유지)
  Widget buildVideoOverlay({
    required ScrollController scrollController,
    required Size viewportSize,
    double collapseScrollPx = 480.0,
    double miniWidth = 360.0,
  }) {
    final vc = VideoSyncService.instance.controller;
    if (vc == null) return const SizedBox.shrink();

    return StickyVideoOverlay(
      controller: vc,
      scrollController: scrollController,
      viewportSize: viewportSize,
      collapseScrollPx: collapseScrollPx,
      miniWidth: miniWidth,
    );
  }

  // ================================================================
  // STOP & UNLOAD CURRENT MEDIA (for screen lifecycle)
  // ================================================================
  /// 현재 재생 중인 오디오/비디오를 완전히 정리한다.
  ///
  /// - FFRW 타이머/플래그 정지
  /// - 네이티브 엔진 pause + closeFile
  /// - mpv 플레이어 pause + stop
  /// - duration/position/playing 스트림을 0/false로 리셋
  ///
  /// EngineApi 싱글톤 자체는 유지하되,
  /// "지금 재생 중인 트랙"만 깨끗하게 없애는 용도.
  Future<void> stopAndUnload() async {
    _logSmpEngine('stopAndUnload(): stopping playback & unloading media');

    // 1) FFRW 정리
    _ffrwTick?.cancel();
    _ffrwTick = null;
    _ff = false;
    _fr = false;
    _ffStartedFromPause = false;
    _frStartedFromPause = false;

    // 2) 네이티브 엔진 정지
    try {
      stPause();
    } catch (_) {
      // ignore
    }

    if (_hasFile) {
      try {
        stCloseFile();
      } catch (_) {
        // ignore
      }
    }

    _hasFile = false;
    _nativePlaying = false;
    _pendingVideoTarget = null;
    _lastPolledPosition = null;
    _endCandidate = false;

    // 3) SoT / duration / playing 상태 리셋
    _duration = Duration.zero;
    _durationCtl.add(_duration);
    _positionCtl.add(Duration.zero);
    _playingCtl.add(false);

    // 4) 비디오 쪽도 정지
    try {
      await _player.pause();
    } catch (_) {
      // ignore
    }
    try {
      await _player.stop();
    } catch (_) {
      // ignore
    }

    _logSmpEngine('stopAndUnload(): done (engine & video stopped)');
  }

  // ================================================================
  // CLEANUP
  // ================================================================
  Future<void> dispose() async {
    _logSmpEngine('dispose(): cleaning up engine & player');

    try {
      _ffrwTick?.cancel();
      _ffrwTick = null;
      _positionTimer?.cancel();
      _positionTimer = null;

      await VideoSyncService.instance.dispose();
      await _player.dispose();
    } catch (_) {}

    stCloseFile();
    stDisposeEngine();

    _hasFile = false;
    _nativePlaying = false;

    await _positionCtl.close();
    await _durationCtl.close();
    await _playingCtl.close();
  }

  // ================================================================
  // UTILS
  // ================================================================
  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  /// duration(SoT 축) 기준 글로벌 클램프
  Duration _clampToDuration(Duration v) {
    if (_duration <= Duration.zero) return Duration.zero;
    return _clamp(v, Duration.zero, _duration);
  }
}

// ================================================================
// PUBLIC FFRW FACADE (UI use)
// ================================================================
class FfRwFacade {
  final EngineApi api;
  FfRwFacade(this.api);

  Future<void> startForward({
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
    required bool loopOn,
  }) {
    return api.fastForward(
      true,
      startCue: startCue,
      loopA: loopOn ? loopA : null,
      loopB: loopOn ? loopB : null,
    );
  }

  Future<void> stopForward() => api.fastForward(false, startCue: Duration.zero);

  Future<void> startReverse({
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
    required bool loopOn,
  }) {
    return api.fastReverse(
      true,
      startCue: startCue,
      loopA: loopOn ? loopA : null,
      loopB: loopOn ? loopB : null,
    );
  }


  Future<void> stopReverse() => api.fastReverse(false, startCue: Duration.zero);
}
