// lib/packages/smart_media_player/smart_media_player_screen.dart
// v3.41

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sync/lesson_memo_sync.dart';
import 'package:path/path.dart' as p;
import '../../ui/components/save_status_indicator.dart';
import '../../ui/components/app_controls.dart'; // ✅ NEW: 공통 UI (AppSection, AppMiniButton, PresetSquare)
import '../../services/lesson_service.dart';

// ===== media_kit =====
import 'ui/smp_control_panel.dart';
import 'ui/smp_transport_bar.dart';
import 'ui/smp_marker_panel.dart';
import '../../ui/components/loop_preset_item.dart';
import 'ui/smp_shortcuts.dart';
import 'ui/smp_waveform_gestures.dart';
import 'ui/smp_notes_panel.dart';
import 'engine/engine_api.dart';
import 'qa/smart_media_player_qa_screen.dart';
import 'video/sticky_video_overlay.dart';

// NEW
import 'package:guitartree/packages/smart_media_player/waveform/system/waveform_system.dart'
    show WaveformController, WfMarker;

import 'waveform/system/waveform_panel.dart';
import 'waveform/waveform_tuning.dart';
import 'models/marker_point.dart';
import 'sync/sidecar_sync_db.dart';
import 'utils/debounced_saver.dart';
import 'loop/loop_executor.dart';

class SmartMediaPlayerScreen extends StatefulWidget {
  final String studentId;
  final String mediaHash;
  final String mediaPath;
  final String studentDir;
  final String? initialSidecar;

  const SmartMediaPlayerScreen({
    super.key,
    required this.studentId,
    required this.mediaHash,
    required this.mediaPath,
    required this.studentDir,
    this.initialSidecar,
  });

  static Future<void> push(
    BuildContext context,
    SmartMediaPlayerScreen screen,
  ) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => screen));
  }

  static Future<void> pushFromPrepared(
    BuildContext context, {
    required String studentId,
    required String mediaHash,
    required String mediaPath,
    required String studentDir,
    String? sidecarPath,
  }) {
    return push(
      context,
      SmartMediaPlayerScreen(
        studentId: studentId,
        mediaHash: mediaHash,
        mediaPath: mediaPath,
        studentDir: studentDir,
        initialSidecar: sidecarPath,
      ),
    );
  }

  @override
  State<SmartMediaPlayerScreen> createState() => _SmartMediaPlayerScreenState();
}

// A~C 패치: WidgetsBindingObserver 믹스인 추가
class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen>
    with WidgetsBindingObserver {
  late LoopExecutor _loopExec;
  late final DebouncedSaver _saver;
  late SmpWaveformGestures _gestures;

  // Engine position 스트림 구독 (SoT 단일 진입점)
  StreamSubscription<Duration>? _positionSub;

  // media_kit
  Timer? _applyDebounce;
  bool _hydratingMemo = false; // 외부 주입 중 플래그

  // 포커스
  final FocusNode _focusNode = FocusNode(debugLabel: 'SMPFocus');

  // [PIP] 스크롤 컨트롤러 (영상 오버레이 축소/고정)
  final ScrollController _scrollCtl = ScrollController();

  final WaveformController _wf = WaveformController();

  // 파라미터
  double _speed = 1.0;
  int _pitchSemi = 0;

  // 🔊 볼륨(0~150)
  int _volume = 100;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;
  int _loopRepeat = 0; // 0=∞
  int _loopRemaining = -1;

  // ===== Unified EngineApi fields (Step 4-1) =====
  Duration _duration = Duration.zero; // engine_api onDuration 콜백에서 갱신됨
  Duration get _position => _wf.position.value;

  void _onScrollTick() {
    if (!mounted) return;
    setState(() {}); // 스크롤 오프셋 변화에 맞춰 오버레이 재계산
  }

  // 시작점
  Duration _startCue = Duration.zero;

  bool _isDisposing = false; // ✅ dispose 중 가드
  VoidCallback? _saverListener; // ✅ 리스너 핸들 보관

  // 마커
  final List<MarkerPoint> _markers = [];

  // 메모
  String _notes = '';
  final TextEditingController _notesCtl = TextEditingController();
  bool _notesInitApplying = true;

  Timer? _afWatchdog;

  // 자동 저장
  Timer? _saveDebounce;

  // ✅ 저장 상태(공용 UI 연동)
  SaveStatus _saveStatus = SaveStatus.idle;
  DateTime? _lastSavedAt;
  int _pendingRetryCount = 0;

  // 워치독
  Timer? _posWatchdog;

  // 오늘 날짜
  late final String _todayDateStr = () {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    return d0.toIso8601String().split('T').first;
  }();

  // ===== 사이드카 경로(로컬) =====
  String get _cacheDir {
    final wsRoot = Directory(widget.studentDir).parent.parent.path;
    return p.join(wsRoot, '.cache');
  }

  @override
  void initState() {
    super.initState();

    // 1) LoopExecutor 초기화
    _loopExec = LoopExecutor(
      getPosition: () => _wf.position.value,
      getDuration: () => _wf.duration.value,
      seek: (d) => EngineApi.instance.seekUnified(d),
      play: () => EngineApi.instance.play(),
      pause: () => EngineApi.instance.pause(),
      onLoopStateChanged: (enabled) {
        setState(() {
          _wf.setLoop(a: _loopA, b: _loopB, on: _loopExec.loopOn);
        });
      },
      onLoopRemainingChanged: (rem) {
        setState(() => _loopRemaining = rem);
      },
      onExitLoop: () async {
        setState(() {
          _loopEnabled = false;
          _wf.setLoop(a: _loopA, b: _loopB, on: false);
        });
        await EngineApi.instance.loopExitToStartCue(_startCue);
      },
    );
    _loopExec.start();

    // A 패치: 라이프사이클 옵저버 등록
    WidgetsBinding.instance.addObserver(this);

    // ✅ 트랜스크라이브 톤(VisualExact + Signed) 기본 적용
    WaveformTuning.I.applyPreset(WaveformPreset.transcribeLike);
    WaveformTuning.I
      ..visualExact = true
      ..useSignedAmplitude = true;

    // saver 초기화 + 상태 listen
    _saver = DebouncedSaver(delay: const Duration(milliseconds: 800));
    _saverListener = () {
      if (!mounted || _isDisposing) return;
      setState(() {
        _saveStatus = _saver.status;
        _lastSavedAt = _saver.lastSavedAt;
        _pendingRetryCount = _saver.pendingRetryCount;
      });
    };
    _saver.addListener(_saverListener!);

    // === 컨트롤러 콜백 (패널 → 화면/플레이어) ===
    _gestures = SmpWaveformGestures(
      waveform: _wf,
      onPause: () => EngineApi.instance.pause(),
      getDuration: () => _duration,
      getStartCue: () => _startCue,
      setStartCue: (d) {
        // STEP 3-4: 루프 중 StartCue 변경 차단
        if (_loopEnabled == true) {
          return;
        }

        final fixed = _normalizeStartCueForLoop(d);

        setState(() {
          _startCue = fixed;
        });

        _logSoTScreen('START_CUE set via gesture', startCue: fixed);
      },
      setPosition: (d) {
        // no-op
      },
      onSeekRequest: (d) async {
        await EngineApi.instance.seekUnified(d);
        _requestSave(saveMemo: false);
      },
      saveDebounced: ({saveMemo = false}) => _requestSave(saveMemo: saveMemo),
    );

    // 파형 기본 힌트 (duration unknown 시)
    _wf.updateFromPlayer(dur: const Duration(minutes: 5));

    // 제스처 시스템 attach (WaveformController 연결)
    _gestures.attach(); // Step 6-B: duration 반영 이후 attach

    // 비동기 초기화 (엔진 load)
    _initAsync();

    // [7-A] PIP auto-collapse 동작을 위한 scroll listener 연결
    _scrollCtl.addListener(_onScrollTick);

    // 포커스 자동 획득
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    // [SYNC]
    _initNotesAndSidecarSync();
    _subscribeLocalNotesBus();
    _startPosWatchdog();

    // 초기 브릿지: Loop/StartCue/Marker → WaveformController
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(_markers.map((m) => WfMarker(m.t, m.label)).toList());

    // === 3-3B: audioChain playbackTime → position single-source ===
    // ✅ P3: _gestures 생성/attach 이후에 position$ listen 등록
    _positionSub = EngineApi.instance.position$.listen((d) {
      if (!mounted || _isDisposing) return;

      // 엔진 기준 SoT
      final enginePos = d;
      final engineDur = _wf.duration.value > Duration.zero
          ? _wf.duration.value
          : _duration;

      // ✅ 단일 진입점: WaveformController에 pos/dur 동기화
      _wf.updateFromPlayer(pos: enginePos, dur: engineDur);

      // 제스처 시스템도 같은 SoT로 맞춤
      _gestures.setPosition(enginePos);

      // TransportBar 등 전체 UI 갱신
      setState(() {});
    });
  }

  // A 패치: 앱 라이프사이클 변화 시 즉시 저장 한번 보장
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(
        _saver.flush(() async {
          // 1) 사이드카 즉시 저장
          await _saveEverything(saveMemo: false);

          // 2) flush 이후 DB 업로드 pending 체크
          final pending = SidecarSyncDb.instance.pendingUploadAt;
          if (pending != null) {
            // 즉시 업로드 시도 (실패하면 pending 유지됨)
            unawaited(SidecarSyncDb.instance.tryUploadNow());
          }
        }),
      );
    }
  }

  Future<void> _initAsync() async {
    await _openMedia();
  }

  // =========================
  // [SYNC] 초기 동기화 시퀀스
  // =========================
  Future<void> _initNotesAndSidecarSync() async {
    _notesInitApplying = true;
    try {
      // 1) DB판 바인딩(+로컬 캐시 경로 전달)
      await SidecarSyncDb.instance.bind(
        studentId: widget.studentId,
        mediaHash: widget.mediaHash,
        localCacheDir: _cacheDir, // 선택
      );
      // 2) 없으면 생성
      await SidecarSyncDb.instance.upsertInitial(initial: const {});
      // 3) 로컬→DB 순서로 로드
      final loaded = await SidecarSyncDb.instance.load();
      if (loaded.isNotEmpty) _applySidecarMap(loaded);
      // 2) lessons.memo 초기값
      String dbMemo = '';
      try {
        final now = DateTime.now();
        final d0 = DateTime(now.year, now.month, now.day);
        final rows = await LessonService().listByStudent(
          widget.studentId,
          from: d0,
          to: d0,
          limit: 1,
        );
        if (rows.isNotEmpty) dbMemo = (rows.first['memo'] ?? '').toString();
      } catch (_) {}
      final sidecarNotes = _notesCtl.text;
      final initMemo = (dbMemo.trim().isNotEmpty) ? dbMemo : sidecarNotes;
      if (initMemo != _notesCtl.text) {
        _notes = initMemo;
        _notesCtl.text = initMemo;
      }

      // 3) Realtime 구독
      _subscribeLessonMemoRealtime();
    } finally {
      _notesInitApplying = false;
    }
    _requestSave(saveMemo: false);
  }

  void _subscribeLessonMemoRealtime() {
    final today = _todayDateStr;

    LessonMemoSync.instance.subscribeRealtime(
      studentId: widget.studentId,
      dateISO: today,
      onMemoChanged: (memo) {
        if (!mounted) return;

        // 변경 없음 → 무시
        if (memo == _notes) return;

        // hydration 시작
        _hydratingMemo = true;

        setState(() {
          _notes = memo;
          _notesCtl.text = memo;
        });

        // sidecar 저장은 hydration 종료 후로 지연
        Future.delayed(const Duration(milliseconds: 50), () {
          _hydratingMemo = false;
          _requestSave(saveMemo: false);
        });
      },
    );
  }

  void _subscribeLocalNotesBus() {
    LessonMemoSync.instance.subscribeLocalBus((text) {
      if (!mounted) return;
      if (text == _notes) return;

      _hydratingMemo = true;

      setState(() {
        _notes = text;
        _notesCtl.text = text;
      });

      Future.delayed(const Duration(milliseconds: 50), () {
        _hydratingMemo = false;
        _requestSave(saveMemo: true);
      });
    });
  }

  @override
  void dispose() {
    _isDisposing = true;

    // P1: 좀비 재생 방지 — 화면 종료 시 엔진/플레이어 완전 정리
    // 화면을 떠나는 순간, 지금 재생 중인 트랙/비디오는 반드시 멈춘다.
    unawaited(EngineApi.instance.stopAndUnload());

    // Engine position 스트림 구독 해제
    _positionSub?.cancel();
    _positionSub = null;

    // 1) saver 리스너 먼저 제거
    if (_saverListener != null) {
      _saver.removeListener(_saverListener!);
      _saverListener = null;
    }

    // 2) 마지막 flush 1회 보장
    try {
      unawaited(
        _saver.flush(() async {
          await _saveEverything(saveMemo: false);
        }),
      );
    } catch (_) {}

    // 3) saver 종료 (flush 이후)
    _saver.dispose();

    // 4) SidecarSyncDb 종료 — 절대 이 위에서 save 호출 금지
    SidecarSyncDb.instance.dispose();

    // 5) 나머지 정리
    LessonMemoSync.instance.dispose();
    _loopExec.stop();
    WidgetsBinding.instance.removeObserver(this);
    _notesCtl.dispose();
    _focusNode.dispose();
    _posWatchdog?.cancel();
    _scrollCtl.dispose();
    _applyDebounce?.cancel();
    _afWatchdog?.cancel();
    _saveDebounce?.cancel();
    _gestures.dispose();

    super.dispose();
  }

  void _applySidecarMap(Map<String, dynamic> m) {
    final a = m['loopA'];
    final b = m['loopB'];
    final sp = m['speed'] ?? 1.0;
    final posMsRaw = m['positionMs'];
    final mk = (m['markers'] as List?)?.cast<dynamic>() ?? const [];
    final ps = m['pitchSemi'] ?? 0;
    final rpRaw = m['loopRepeat'] ?? 0;
    final scRaw = m['startCueMs'];
    final notes = (m['notes'] as String?) ?? '';
    final vol = m['volume'] ?? 100;

    // 🔥 타입 안전하게 변환
    final loopAms = (a is num) ? a.toInt() : 0;
    final loopBms = (b is num) ? b.toInt() : 0;
    final posMs = (posMsRaw is num) ? posMsRaw.toInt() : 0;
    final scMs = (scRaw is num) ? scRaw.toInt() : 0;

    setState(() {
      _loopA = loopAms > 0 ? Duration(milliseconds: loopAms) : null;
      _loopB = loopBms > 0 ? Duration(milliseconds: loopBms) : null;

      final loopOnWant = (m['loopOn'] ?? false) == true;
      _loopEnabled =
          loopOnWant && _loopA != null && _loopB != null && _loopA! < _loopB!;

      _speed = (sp as num).toDouble().clamp(0.5, 1.5);
      _loopRepeat = (rpRaw as num).toInt().clamp(0, 200);
      _loopRemaining = -1;
      _pitchSemi = (ps as num).toInt().clamp(-7, 7);

      // STEP 2-P1:
      //  - 여기서는 duration=0 상태에서도 원시 sidecar 값을 그대로 싣고,
      //  - 실제 duration이 준비된 이후 _normalizeTimedState()에서 정규화한다.
      _startCue = Duration(milliseconds: scMs);

      _notes = notes;
      _notesCtl.text = notes;

      _volume = (vol as num).toInt().clamp(0, 150);

      _markers
        ..clear()
        ..addAll(
          mk.whereType<Map>().map(
            (e) => MarkerPoint.fromJson(Map<String, dynamic>.from(e)),
          ),
        );

      // duration이 이미 준비된 상태라면 이 시점에서 정규화
      _normalizeTimedState();
    });

    _logSoTScreen('APPLY_SIDECAR (loop/startCue restored)');

    // === 위치 적용 ===
    if (posMs > 0) {
      final d = Duration(milliseconds: posMs);

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // STEP 2-P1: EngineApi/Waveform duration 중 실제 값이 준비된 이후에만 적용
        final dur = _effectiveDuration;
        if (dur != Duration.zero && d < dur) {
          await EngineApi.instance.seekUnified(d);
        }
      });
    }

    // === Waveform 반영 ===
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(
      _markers
          .map((e) => WfMarker.named(time: e.t, label: e.label, color: e.color))
          .toList(),
    );
    final effDur = _effectiveDuration;
    if (effDur != Duration.zero) {
      _wf.setDuration(effDur);
      _wf.updateFromPlayer(dur: effDur);
    }
  }

  // ==== 이하 재생/체인/파형/루프/마커/키핸들 ===

  void _startPosWatchdog() {
    _posWatchdog?.cancel();
    const period = Duration(seconds: 1);
    int silentTicks = 0;
    Duration last = Duration.zero;

    _posWatchdog = Timer.periodic(period, (_) {
      if (_position == last) {
        silentTicks++;
        if (silentTicks >= 5) {
          debugPrint(
            '[SMP] position steady 5s (playing=${EngineApi.instance.isPlaying})',
          );
          _logSoTScreen('WATCHDOG steady 5s');
          silentTicks = 0;
        }
      } else {
        silentTicks = 0;
        last = _position;
      }
    });
  }

  Future<void> _openMedia() async {
    await EngineApi.instance.load(
      path: widget.mediaPath,
      onDuration: (d) {
        final engineDuration = d;
        final waveDuration = _wf.duration.value;

        // STEP 2-P1:
        //  - FFmpeg(EngineApi)의 duration을 마스터로 사용
        //  - 필요 시 Waveform duration을 보조로 활용
        final safeDuration = engineDuration > Duration.zero
            ? engineDuration
            : (waveDuration > Duration.zero ? waveDuration : Duration.zero);

        setState(() {
          _duration = safeDuration;
          // duration이 준비되었으므로 sidecar 기반 시간값 정규화
          _normalizeTimedState();
        });

        // Waveform에도 동일 duration 및 loop/startCue 반영
        _wf.setDuration(safeDuration);
        _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
        _wf.setStartCue(_startCue);

        // duration 즉시 반영 → transportBar/loop-panel 반응 개선
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isDisposing) {
            _wf.updateFromPlayer(dur: safeDuration);
            setState(() {});
          }
        });
      },
    );

    _logSoTScreen('OPEN_MEDIA done (duration=${_fmt(_duration)})');
  }

  // === 단축키 안내 다이얼로그 ===
  void _showHotkeys() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('단축키 안내'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('재생/일시정지(시작점): Space'),
              Text('루프 토글: L  •  루프 시작/끝 지정: E / D'),
              Text('마커 추가: M'),
              Text('마커 점프: Alt+1~9  •  이전/다음: Alt+←/→'),
              Text('템포 조절: [ 5% 느리게  ,  ] 5% 빠르게'),
              Text('템포 프리셋: 5~0 = 50%~100%'),
              Text('키 조정(반음): Alt+↑ / Alt+↓'),
              SizedBox(height: 8),
              Text('  =  키를 누르고 있는 동안 4x 재생'),
              Text('  -  키를 누르고 있는 동안 4x 역재생'),
              Text('줌인/줌아웃: Alt+=  /  Alt+-'),
              Text('줌 리셋: Alt+0'),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 6-D: 저장 루틴 단일화 (ENTRY POINT)
  // ============================================================
  void _requestSave({bool saveMemo = true}) {
    if (_isDisposing) return;

    _saver.schedule(() async {
      // dispose 중에는 flush만 허용
      if (_isDisposing) return;

      await _saveEverything(saveMemo: saveMemo);
    });
  }

  // ============================================================
  // 6-D: LWW(Latest-Write-Wins) + Sidecar/Memo 충돌 제거
  // ============================================================
  Future<void> _saveEverything({bool saveMemo = true}) async {
    if (_isDisposing) return;

    // 메모 hydration 중이면 sidecar overwrite 금지
    if (_hydratingMemo && saveMemo) {
      // 메모는 hydration 상태에서는 저장 스킵
      saveMemo = false;
    }

    final now = DateTime.now();

    // STEP 2-P1: 저장 직전에 시간계 상태를 duration 기준으로 정규화
    _normalizeTimedState();

    final map = {
      'studentId': widget.studentId,
      'mediaHash': widget.mediaHash,
      'speed': _speed,
      'pitchSemi': _pitchSemi,
      'loopA': _loopA?.inMilliseconds ?? 0,
      'loopB': _loopB?.inMilliseconds ?? 0,
      'loopOn': _loopEnabled,
      'loopRepeat': _loopRepeat,
      'positionMs': _position.inMilliseconds,
      'startCueMs': _startCue.inMilliseconds,
      'savedAt': now.toIso8601String(),
      'media': p.basename(widget.mediaPath),
      'version': 'v3.07.2',
      'markers': _markers.map((e) => e.toJson()).toList(),
      'notes': _notes,
      'volume': _volume,
    };

    try {
      // 1) sidecar 저장 (LWW 내부에서 자동 해결)
      await SidecarSyncDb.instance.save(map, debounce: false);

      // 2) memo 저장 (hydratingMemo에서는 skip)
      if (saveMemo && !_hydratingMemo) {
        await LessonMemoSync.instance.upsertMemo(
          studentId: widget.studentId,
          dateISO: _todayDateStr,
          memo: _notes,
        );
      }

      // 3) pendingUploadAt → 즉시 업로드 시도
      await SidecarSyncDb.instance.tryUploadNow();

      if (mounted) {
        setState(() {
          _saveStatus = SaveStatus.saved;
          _lastSavedAt = now;
          _pendingRetryCount = 0;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveStatus = SaveStatus.failed);
    }
  }

  // ===== 2x 정/역재생(홀드) =====
  //
  // P3 규칙:
  //  - FF/FR은 항상 현재 pos 기준 자유 이동
  //  - StartCue/Loop는 FF/FR에 하한/상한으로 개입하지 않는다.
  //
  // 따라서 FFRW 엔트리에는 항상 "중립값"을 전달한다.
  Future<void> _startHoldFastForward() async {
    await EngineApi.instance.ffrw.startForward(
      startCue: Duration.zero,
      loopA: null,
      loopB: null,
      loopOn: false,
    );
    setState(() {}); // waveform/timeline 즉시 반응
  }

  Future<void> _stopHoldFastForward() => EngineApi.instance.ffrw.stopForward();

  Future<void> _startHoldFastReverse() async {
    await EngineApi.instance.ffrw.startReverse(
      startCue: Duration.zero,
      loopA: null,
      loopB: null,
      loopOn: false,
    );
  }

  Future<void> _stopHoldFastReverse() => EngineApi.instance.ffrw.stopReverse();

  // ============================================================
  // STEP 3-4 / 4-1 — Duration clamp helper (v3.41)
  // ============================================================
  Duration _clamp(Duration x, Duration min, Duration max) {
    if (x < min) return min;
    if (x > max) return max;
    return x;
  }

  // ============================================================
  // P2 — FFmpeg SoT 기반 duration 단일화
  //  - EngineApi.duration(FFmpeg) 우선
  //  - WaveformController.duration 보조
  // ============================================================
  Duration get _effectiveDuration {
    if (_duration > Duration.zero) return _duration;
    if (_wf.duration.value > Duration.zero) return _wf.duration.value;
    return Duration.zero;
  }

  // ============================================================
  // P2 — loopA/loopB/StartCue/loopRepeat 저장 직전 정규화
  //
  //  - _effectiveDuration 기준으로 loopA/B/startCue를 clamp
  //  - loopA >= loopB 이면 loop 해제
  //  - loopRepeat은 [0,200] 범위로 강제
  //  - WaveformController에도 동일 상태를 반영
  // ============================================================
    void _normalizeTimedState() {
    final dur = _effectiveDuration;

    // duration 미정이면 최소한 음수만 막고 return
    if (dur <= Duration.zero) {
      if (_loopA != null && _loopA! < Duration.zero) {
        _loopA = Duration.zero;
      }
      if (_loopB != null && _loopB! < Duration.zero) {
        _loopB = Duration.zero;
      }
      if (_startCue < Duration.zero) {
        _startCue = Duration.zero;
      }
      // duration이 아직 없을 땐 LoopExecutor를 굳이 건드리지 않는다.
      return;
    }

    Duration? a = _loopA;
    Duration? b = _loopB;

    if (a != null) {
      a = _clamp(a, Duration.zero, dur);
    }
    if (b != null) {
      b = _clamp(b, Duration.zero, dur);
    }

    bool loopValid = false;
    if (a != null && b != null && a < b) {
      loopValid = true;
    } else {
      // 잘못된 루프는 과감히 해제
      a = null;
      b = null;
    }

    _loopA = a;
    _loopB = b;
    _loopEnabled = loopValid && _loopEnabled;

    // 루프 반복 횟수는 0~200 사이로 강제
    _loopRepeat = _loopRepeat.clamp(0, 200);

    // StartCue는 loop 규칙을 포함한 정규화 규칙 사용
    _startCue = _normalizeStartCueForLoop(_startCue);

    // WaveformController와 동기화
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    // 🔥 NEW: LoopExecutor 상태도 함께 정합 유지
    _loopExec.setLoopEnabled(_loopEnabled);
    if (_loopA != null) {
      _loopExec.setA(_loopA!);
    }
    if (_loopB != null) {
      _loopExec.setB(_loopB!);
    }
    _loopExec.setRepeat(_loopRepeat);

    _logSoTScreen(
      'NORMALIZE_TIMED_STATE',
      pos: _position,
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }


  // 키 업/다운 핸들 (=-)
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) {
    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    final hasBlockMods =
        mods.contains(LogicalKeyboardKey.alt) ||
        mods.contains(LogicalKeyboardKey.altLeft) ||
        mods.contains(LogicalKeyboardKey.altRight) ||
        mods.contains(LogicalKeyboardKey.control) ||
        mods.contains(LogicalKeyboardKey.meta);

    if (hasBlockMods) {
      return KeyEventResult.ignored;
    }

    // P3: FF/FR 단축키도 StartCue/Loop에 구속되지 않는
    // "자유 타임라인 스캔"으로 고정.
    if (evt.logicalKey == LogicalKeyboardKey.equal) {
      if (evt is KeyDownEvent) {
        EngineApi.instance.ffrw.startForward(
          startCue: Duration.zero,
          loopA: null,
          loopB: null,
          loopOn: false,
        );
      } else if (evt is KeyUpEvent) {
        EngineApi.instance.ffrw.stopForward();
      }
      return KeyEventResult.handled;
    }

    if (evt.logicalKey == LogicalKeyboardKey.minus) {
      if (evt is KeyDownEvent) {
        EngineApi.instance.ffrw.startReverse(
          startCue: Duration.zero,
          loopA: null,
          loopB: null,
          loopOn: false,
        );
      } else if (evt is KeyUpEvent) {
        EngineApi.instance.ffrw.stopReverse();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final title = p.basename(widget.mediaPath);

    return Listener(
      onPointerDown: (_) {
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
      },
      child: SmpsShortcuts(
        focusNode: _focusNode,

        // ===== 단축키 매핑 =====
        onPlayFromStartOrPause: () =>
            EngineApi.instance.spaceBehavior(_startCue),
        onToggleLoop: () {
          _loopToggleMain(!_loopEnabled);
        },
        onLoopASet: () => _loopSetA(_wf.position.value),
        onLoopBSet: () => _loopSetB(_wf.position.value),
        onMarkerAdd: _addMarker,
        onMarkerJump: _jumpToMarkerIndex,
        onMarkerPrev: () => _jumpPrevNextMarker(next: false),
        onMarkerNext: () => _jumpPrevNextMarker(next: true),
        onZoom: (zoomIn) {
          final delta = zoomIn ? 1.10 : 0.90;
          // 화면 중심 기준 zoom
          _gestures.zoomAt(cursorFrac: 0.5, factor: delta);
        },
        onZoomReset: _gestures.zoomReset,
        onPitchNudge: _pitchDelta,
        onSpeedPreset: _setSpeed,
        onSpeedNudge: _nudgeSpeed,
        onKeyEvent: _onKeyEvent,

        // ===== 실제 화면 =====
        child: Scaffold(
          appBar: AppBar(
            title: Text('스마트 미디어 플레이어 — $title'),
            actions: [
              // === 3-3C: pendingUploadAt 배지 ===
              ValueListenableBuilder<DateTime?>(
                valueListenable: SidecarSyncDb.instance.pendingUploadAtNotifier,
                builder: (ctx, pendingAt, child) {
                  final hasPending = pendingAt != null;
                  return AnimatedSwitcher(
                    // 🔥 깜빡임 제거
                    duration: const Duration(milliseconds: 150),
                    child: hasPending
                        ? Container(
                            key: const ValueKey('pending'),
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '업로드 대기중',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('none')),
                  );
                },
              ),
              IconButton(
                tooltip: '단축키 안내',
                onPressed: _showHotkeys,
                icon: const Icon(Icons.help_outline),
              ),
              IconButton(
                tooltip: 'QA Tools',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SmartMediaPlayerQaScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.bug_report),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (ctx, c) {
              final double viewportW = c.maxWidth;
              final double viewportH = c.maxHeight;
              final double videoMaxHeight = EngineApi.instance.hasVideo
                  ? viewportW * 9 / 16
                  : 0.0;

              return Stack(
                children: [
                  // === 본문 ===
                  SingleChildScrollView(
                    controller: _scrollCtl,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight - 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (EngineApi.instance.hasVideo) ...[
                            SizedBox(height: videoMaxHeight, width: viewportW),
                            const SizedBox(height: 12),
                          ],

                          // === 파형 ===
                          AppSection(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: WaveformPanel(
                                controller: _wf,
                                mediaPath: widget.mediaPath,
                                mediaHash: widget.mediaHash,
                                cacheDir: _cacheDir,
                                onStateDirty: () => _requestSave(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),

                          // === 트랜스포트 바 ===
                          SmpTransportBar(
                            position: _wf.position.value,
                            duration: _wf.duration.value,
                            isPlaying: EngineApi.instance.isPlaying,
                            fmt: _fmt,
                            onPlayPause: () =>
                                EngineApi.instance.spaceBehavior(_startCue),
                            onHoldReverseStart: _startHoldFastReverse,
                            onHoldReverseEnd: _stopHoldFastReverse,
                            onHoldForwardStart: _startHoldFastForward,
                            onHoldForwardEnd: _stopHoldFastForward,
                            loopA: _loopA,
                            loopB: _loopB,
                            loopEnabled: _loopExec.loopOn,
                            loopRepeat: _loopRepeat,
                            loopRemaining: _loopRemaining,
                            onLoopASet: () => _loopSetA(_position),
                            onLoopBSet: () => _loopSetB(_position),
                            onLoopToggle: _loopToggleMain,
                            onLoopRepeatMinus1: () => _loopRepeatDelta(-1),
                            onLoopRepeatPlus1: () => _loopRepeatDelta(1),
                            onLoopRepeatLongMinus5: () => _loopRepeatDelta(-5),
                            onLoopRepeatLongPlus5: () => _loopRepeatDelta(5),
                            onLoopRepeatPrompt: _loopPromptRepeat,
                            onLoopPresetSelected: _loopApplyPreset,
                            onZoomOut: () {
                              _gestures.zoomAt(cursorFrac: 0.5, factor: 0.90);
                            },
                            onZoomReset: _gestures.zoomReset,
                            onZoomIn: () {
                              _gestures.zoomAt(cursorFrac: 0.5, factor: 1.10);
                            },
                            loopPresets: _loopPresets,
                          ),

                          const SizedBox(height: 4),

                          // StartCue / Loop Indicator (UI-only)
                          Row(
                            children: [
                              Icon(
                                Icons.flag,
                                size: 16,
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.9),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Start Cue: ${_fmt(_startCue)}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              if (_loopA != null && _loopB != null) ...[
                                const SizedBox(width: 12),
                                Text(
                                  'Loop: ${_fmt(_loopA!)} ~ ${_fmt(_loopB!)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),

                          const SizedBox(height: 5),

                          // === Control Panel ===
                          SmpControlPanel(
                            speed: _speed,
                            pitchSemi: _pitchSemi,
                            volume: _volume,
                            onSpeedChanged: _setSpeed,
                            onSpeedNudged: _nudgeSpeed,
                            onPitchSet: _setPitch,
                            onPitchNudged: _pitchDelta,
                            onVolumeSet: _setVolume,
                            onVolumeNudged: _nudgeVolume,
                          ),

                          const SizedBox(height: 5),

                          // === Marker Panel ===
                          SmpMarkerPanel(
                            markers: _markers,
                            onAdd: _addMarker,
                            onJumpIndex: _jumpToMarkerIndex,
                            onEdit: _editMarker,
                            onDelete: _deleteMarker,
                            onJumpPrev: () => _jumpPrevNextMarker(next: false),
                            onJumpNext: () => _jumpPrevNextMarker(next: true),
                            fmt: _fmt,
                            onReorder: _reorderMarker,
                          ),

                          const SizedBox(height: 6),
                          const Text('마커 점프: Alt+1..9'),
                          const SizedBox(height: 12),

                          SmpNotesPanel(
                            controller: _notesCtl,
                            onChanged: (v) {
                              if (_notesInitApplying) return;
                              _notes = v;
                              _requestSave(saveMemo: true);
                              LessonMemoSync.instance.pushLocal(v);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (EngineApi.instance.hasVideo)
                    StickyVideoOverlay(
                      controller: EngineApi.instance.videoController!,
                      scrollController: _scrollCtl,
                      viewportSize: Size(viewportW, viewportH),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ===============================================================
  // STEP 3-1 — Loop Logic Consolidation
  // ===============================================================

  // 현장 최적화 4종 (1/2/4/8마디) — TransportBar에서 요구하는 LoopPresetItem 사용
  static const List<LoopPresetItem> _loopPresets = [
    LoopPresetItem('1마디 · 50회', 50),
    LoopPresetItem('2마디 · 30회', 30),
    LoopPresetItem('4마디 · 20회', 20),
    LoopPresetItem('8마디 · 12회', 12),
  ];

  // A. Loop Toggle ------------------------------------------------

  // E/D로 루프 범위를 잡을 때,
  // "앞쪽 점 하나"를 StartCue + LoopA로 맞추기 위한 헬퍼.
  Duration _computeStartCueFromLoopOrPos(Duration fallbackPos) {
    // 1) 우선 loopA/loopB 중 앞쪽 점이 있으면 그걸 쓰고
    // 2) 둘 다 없으면 지금 위치(fallbackPos)를 사용
    Duration candidate = fallbackPos;

    if (_loopA != null && _loopB != null) {
      candidate = _loopA! <= _loopB! ? _loopA! : _loopB!;
    } else if (_loopA != null) {
      candidate = _loopA!;
    } else if (_loopB != null) {
      candidate = _loopB!;
    }

    // 최종적으로 duration/loop 규칙에 맞게 정규화
    return _normalizeStartCueForLoop(candidate);
  }

  void _loopToggleMain(bool on) {
    _loopExec.setLoopEnabled(on);

    // Engine 반영 직후 UI 즉시 업데이트
    final newOn = _loopExec.loopOn;
    _loopEnabled = newOn;

    setState(() {});
    _requestSave();

    _logSoTScreen('LOOP_TOGGLE on=$newOn');
  }

  // B. Loop A/B Points -------------------------------------------

  void _loopSetA(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    setState(() {
      // 1) 루프 앞점(A) 갱신
      _loopA = clamped;
      _loopExec.setA(clamped);

      // 2) "앞점 = StartCue" 규칙
      //    - duration/loop 규칙을 포함해서 정규화
      _startCue = _normalizeStartCueForLoop(clamped);
    });

    // Waveform와 동기화
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    // NEW: UI 즉시 갱신
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });

    _requestSave();

    _logSoTScreen('LOOP_SET_A', loopA: _loopA, startCue: _startCue);
  }

  void _loopSetB(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    // 아직 A가 없으면: "앞점부터 세팅" (E와 같은 의미)
    if (_loopA == null) {
      _loopSetA(clamped);
      return;
    }

    _loopExec.setB(clamped);

    setState(() {
      _loopB = _loopExec.loopB;
      _loopEnabled = _loopExec.loopOn;

      // B가 바뀌면 StartCue가 loop 범위 밖으로 튀지 않게만 보정
      _startCue = _normalizeStartCueForLoop(_startCue);
    });

    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    _requestSave();

    _logSoTScreen(
      'LOOP_SET_B',
      loopA: _loopA,
      loopB: _loopB,
      startCue: _startCue,
    );
  }

  // C. Loop Repeat ------------------------------------------------

  Future<void> _loopSetRepeat(int v) async {
    _loopExec.setRepeat(v);

    setState(() {
      _loopRepeat = _loopExec.repeat;
      _loopRemaining = _loopExec.remaining;
    });

    _wf.loopRepeat.value = _loopRepeat;
    _requestSave();

    _logSoTScreen(
      'LOOP_REPEAT_SET repeat=$_loopRepeat remaining=$_loopRemaining',
    );
  }

  void _loopRepeatDelta(int delta) {
    _loopSetRepeat(_loopRepeat + delta);
  }

  // D. Loop Preset -----------------------------------------------

  Future<void> _loopApplyPreset(int repeat) async {
    await _loopSetRepeat(repeat);
  }

  Future<void> _loopPromptRepeat() async {
    final ctl = TextEditingController(text: _loopRepeat.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('반복횟수 입력 (0=∞)'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('확인'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final n = int.tryParse(ctl.text.trim()) ?? _loopRepeat;
      await _loopApplyPreset(n);
    }
  }

  // E. StartCue <-> A sync ---------------------------------------

  // === Speed ===
  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v.clamp(0.5, 1.5));
    await EngineApi.instance.setTempo(_speed);
    _requestSave();
  }

  Future<void> _nudgeSpeed(int deltaPercent) async {
    final step = deltaPercent / 100.0;
    await _setSpeed(_speed + step);
  }

  // === Pitch ===
  Future<void> _pitchDelta(int d) async {
    setState(() {
      _pitchSemi = (_pitchSemi + d).clamp(-7, 7);
    });
    await EngineApi.instance.setPitch(_pitchSemi);
    _requestSave();
  }

  Future<void> _setPitch(int semis) async {
    setState(() => _pitchSemi = semis.clamp(-7, 7));
    await EngineApi.instance.setPitch(_pitchSemi);
    _requestSave();
  }

  // === Volume ===
  Future<void> _setVolume(int v) async {
    setState(() => _volume = v.clamp(0, 150));
    await EngineApi.instance.setVolume(_volume / 100.0);
    _requestSave();
  }

  Future<void> _nudgeVolume(int delta) async {
    await _setVolume(_volume + delta);
  }

  // ============================================================
  // P2 — Screen 레벨 SoT 로깅 헬퍼
  //  - EngineApi 쪽 로그와 겹치지 않게 prefix 분리
  // ============================================================
  void _logSoTScreen(
    String label, {
    Duration? pos,
    Duration? startCue,
    Duration? loopA,
    Duration? loopB,
  }) {
    final effDur = _effectiveDuration;
    final buf = StringBuffer('[SMP/Screen] $label');

    if (pos != null) {
      buf.write(' pos=${pos.inMilliseconds}ms');
    }
    if (startCue != null) {
      buf.write(' sc=${startCue.inMilliseconds}ms');
    }
    if (loopA != null || loopB != null) {
      buf.write(
        ' loopA=${loopA?.inMilliseconds}ms, loopB=${loopB?.inMilliseconds}ms',
      );
    }
    if (effDur > Duration.zero) {
      buf.write(' dur=${effDur.inMilliseconds}ms');
    }

    debugPrint(buf.toString());
  }

  // ============================================================
  // 공통 타임 포맷터 (mm:ss)
  //  - 필요하면 나중에 mm:ss.SS로 확장 가능
  // ============================================================
  String _fmt(Duration d) {
    if (d < Duration.zero) d = Duration.zero;
    final totalSeconds = d.inMilliseconds ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  void _addMarker() {
    final idx = _markers.length + 1;
    final label = _lettersForIndex(idx);
    final pos = _wf.position.value;

    _markers.add(MarkerPoint(pos, label));
    _wf.setMarkers(_markers.map((m) => WfMarker(m.t, m.label)).toList());
    _requestSave();

    debugPrint('[SMP-MARKER] ADD idx=$idx label=$label t=${_fmt(pos)}');
    _logSoTScreen('MARKER_ADD idx=$idx', pos: pos);
  }

  String _lettersForIndex(int n1based) {
    int n = n1based - 1;
    final buf = <int>[];
    do {
      buf.add(n % 26);
      n = (n ~/ 26) - 1;
    } while (n >= 0);
    return String.fromCharCodes(buf.reversed.map((e) => 65 + e));
  }

  Future<void> _editMarker(int index) async {
    if (index < 0 || index >= _markers.length) return;
    final m = _markers[index];
    final labelCtl = TextEditingController(text: m.label);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('마커 이름 편집'),
        content: TextField(
          controller: labelCtl,
          decoration: const InputDecoration(labelText: '마커 이름'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      setState(() {
        final newLabel = labelCtl.text.trim();
        if (newLabel.isNotEmpty) m.label = newLabel;
      });
      _wf.setMarkers(
        _markers
            .map(
              (e) => WfMarker.named(time: e.t, label: e.label, color: e.color),
            )
            .toList(),
      );
      _requestSave();

      debugPrint(
        '[SMP-MARKER] EDIT idx=$index label="$m.label" t=${_fmt(m.t)}',
      );
      _logSoTScreen('MARKER_EDIT idx=$index', pos: m.t);
    }
  }

  Future<void> _jumpToMarkerIndex(int i1based) async {
    final i = i1based - 1;
    if (i < 0 || i >= _markers.length) return;

    final t = _markers[i].t;
    final wasPlaying = EngineApi.instance.isPlaying;

    await EngineApi.instance.seekUnified(t);

    // loop 범위 재정합 (시크 이후 startCue 고려)
    _startCue = _normalizeStartCueForLoop(_startCue);

    // UI 즉시 업데이트
    setState(() {});

    // 재생 중이었으면 계속 재생 유지
    if (wasPlaying) {
      await EngineApi.instance.play();
    }

    debugPrint(
      '[SMP-MARKER] JUMP idx=$i1based label="${_markers[i].label}" t=${_fmt(t)}',
    );
    _logSoTScreen('MARKER_JUMP idx=$i1based', pos: t);
  }

  Future<void> _jumpPrevNextMarker({required bool next}) async {
    if (_markers.isEmpty || _duration == Duration.zero) return;

    final nowMs = _position.inMilliseconds;
    final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));
    final wasPlaying = EngineApi.instance.isPlaying;

    Duration? target;

    if (next) {
      // 다음 마커
      for (final m in sorted) {
        if (m.t.inMilliseconds > nowMs) {
          target = m.t;
          break;
        }
      }
      target ??= sorted.last.t; // wrap
    } else {
      // 이전 마커
      for (int i = sorted.length - 1; i >= 0; i--) {
        if (sorted[i].t.inMilliseconds < nowMs) {
          target = sorted[i].t;
          break;
        }
      }
      target ??= sorted.first.t; // wrap
    }

    if (target == null) return;

    await EngineApi.instance.seekUnified(target);

    // loop 정합 보정
    _startCue = _normalizeStartCueForLoop(_startCue);

    // UI 즉시 업데이트
    setState(() {});

    if (wasPlaying) {
      await EngineApi.instance.play();
    }

    debugPrint(
      '[SMP-MARKER] JUMP_${next ? 'NEXT' : 'PREV'}'
      ' t=${_fmt(target)} now=${_fmt(Duration(milliseconds: nowMs))}',
    );
    _logSoTScreen('MARKER_JUMP_${next ? 'NEXT' : 'PREV'}', pos: target);
  }

  void _reorderMarker(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _markers.length) return;

    // ReorderableListView에서 newIndex가 length까지 올 수 있음
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= _markers.length) {
      newIndex = _markers.length - 1;
    }

    setState(() {
      final item = _markers.removeAt(oldIndex);
      _markers.insert(newIndex, item);

      _wf.setMarkers(
        _markers
            .map(
              (e) => WfMarker.named(time: e.t, label: e.label, color: e.color),
            )
            .toList(),
      );
    });

    _requestSave();
  }

  void _deleteMarker(int index) {
    if (index < 0 || index >= _markers.length) return;
    final removed = _markers[index];

    setState(() => _markers.removeAt(index));
    _wf.setMarkers(
      _markers
          .map((e) => WfMarker.named(time: e.t, label: e.label, color: e.color))
          .toList(),
    );
    _requestSave();

    debugPrint(
      '[SMP-MARKER] DELETE idx=$index label="${removed.label}" t=${_fmt(removed.t)}',
    );
    _logSoTScreen('MARKER_DELETE idx=$index', pos: removed.t);
  }

  // ============================================================
  // P2 — StartCue 정규화 규칙 단일화
  //
  //  - 항상 [0, duration] 범위에서 clamp
  //  - 유효한 loopA/B가 있으면:
  //      * startCue < loopA → loopA로 올림
  //      * startCue > loopB → loopA로 워프 (엔진 규칙과 동일)
  // ============================================================
  Duration _normalizeStartCueForLoop(Duration sc) {
    final dur = _effectiveDuration;
    if (dur <= Duration.zero) {
      // duration 미정이면 음수만 방지
      if (sc < Duration.zero) return Duration.zero;
      return sc;
    }

    var v = _clamp(sc, Duration.zero, dur);

    if (_loopA != null && _loopB != null && _loopA! < _loopB!) {
      final a = _clamp(_loopA!, Duration.zero, dur);
      final b = _clamp(_loopB!, Duration.zero, dur);

      if (v < a) v = a;
      if (v > b) v = a; // loop 범위 밖이면 항상 loopA로 귀속
    }

    return v;
  }
}
