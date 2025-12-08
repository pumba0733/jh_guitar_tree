// lib/packages/smart_media_player/smart_media_player_screen.dart
// v3.41 + Step 3 / P2-P3 이후 Screen-level seek/play guard 패치

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

  // ===== Timed state normalization snapshot (change detection) =====
  Duration? _lastNormLoopA;
  Duration? _lastNormLoopB;
  bool _lastNormLoopEnabled = false;
  Duration _lastNormStartCue = Duration.zero;
  Duration _lastNormDuration = Duration.zero;

  // 🔥 Timed state 정규화 재진입 가드 (StackOverflow 방지용)
  bool _isNormalizingTimedState = false;

  bool _isDisposing = false; // ✅ dispose 중 가드
  VoidCallback? _saverListener; // ✅ 리스너 핸들 보관

  // 마커
  final List<MarkerPoint> _markers = [];

  // 마커 네비게이션 커서
  //  - Alt+←/→로 점프할 때 마지막으로 이동한 위치를 기준으로 삼는다.
  //  - 재생 중에는 _position을, 점프 이후에는 이 커서를 우선 사용.
  Duration? _markerNavCursor;

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

  // ===== Screen-level EngineApi 호출 가드 상태 =====
  bool _seekInFlight = false;
  Duration? _seekInFlightTarget;

  bool _playInFlight = false;

  // 🔥 Space(Play/Pause) 입력 가드 (key repeat / 중복 호출 방지)
  DateTime? _lastSpaceInvokedAt;
  bool _spaceInFlight = false;

  @override
  void initState() {
    super.initState();

    // 1) LoopExecutor 초기화
    _loopExec = LoopExecutor(
      getPosition: () => _wf.position.value,
      getDuration: () => _wf.duration.value,
      // ✅ Screen-level seek 게이트 사용
      seek: (d) => _engineSeekFromScreen(d),
      // ✅ Screen-level play 게이트 사용
      play: () => _enginePlayFromScreen(),
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
        // P3 규칙:
        //  - Loop ON/OFF와 무관하게 StartCue는 언제든지 수정 가능
        //  - 단, 유효한 루프가 있을 경우 "루프 밖이면 앞점(A)로 스냅"만 적용
        final fixed = _normalizeStartCueForLoop(d);

        setState(() {
          _startCue = fixed;
        });

        // WaveformController에도 즉시 반영
        _wf.setStartCue(_startCue);

        _logSoTScreen('START_CUE set via gesture', startCue: fixed);
      },
      
      setPosition: (d) {
        // no-op: pos는 EngineApi.position 스트림 → WaveformController 단일 경로
      },
      onSeekRequest: (d) async {
        // 🔥 P3 공통 규칙:
        //  - 재생 중이면 seek 후 계속 재생
        //  - 정지면 seek 후 정지 유지
        //  - Loop/StartCue는 이 경로에서 상/하한으로 개입하지 않음
        await _engineSeekAndMaybeResumeFromScreen(d);
        _requestSave(saveMemo: false);
      },
      saveDebounced: ({saveMemo = false}) => _requestSave(saveMemo: saveMemo),
      isPlaying: () => EngineApi.instance.isPlaying,
    );

    // 파형 기본 힌트 (duration unknown 시)
    _wf.updateFromPlayer(dur: const Duration(minutes: 5));

    // 제스처 시스템 attach (WaveformController 연결)
    _gestures.attach(); // Step 6-B: duration 반영 이후 attach
    // 제스처(WaveformPanel) → Screen 콜백 연결
    _wf.onLoopSet = _onLoopSetFromPanel;
    _wf.onStartCueSet = _onStartCueFromPanel;
    _wf.onMarkersChanged = _onMarkersChangedFromWaveform; // 🔹 NEW: 마커 동기화   

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
    // EngineApi가 StartCue를 항상 Screen 상태에서 가져가도록 연결
    EngineApi.instance.startCueProvider = () => _startCue;

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
    unawaited(EngineApi.instance.stopAndUnload());
    // 이 Screen이 사라질 땐 StartCue provider도 정리
    EngineApi.instance.startCueProvider = null;


    _positionSub?.cancel();
    _positionSub = null;

    if (_saverListener != null) {
      _saver.removeListener(_saverListener!);
      _saverListener = null;
    }

    try {
      unawaited(
        _saver.flush(() async {
          await _saveEverything(saveMemo: false);
        }),
      );
    } catch (_) {}

    _saver.dispose();
    SidecarSyncDb.instance.dispose();
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
      _markerNavCursor = null; // 🔹 마커 커서 초기화
      _normalizeTimedState();
    });

        // 🔁 여기부터 추가: LoopExecutor / WaveformController와 동기화
    //    - LoopExecutor는 Duration(non-null)만 받으므로 null-safe하게 처리
    if (_loopEnabled && _loopA != null && _loopB != null) {
      // 유효한 루프가 있을 때만 A/B를 갱신하고 ON
      _loopExec.setA(_loopA!);
      _loopExec.setB(_loopB!);
      _loopExec.setLoopEnabled(true);
    } else {
      // 루프가 없거나 비활성화면 실행기도 OFF
      _loopExec.setLoopEnabled(false);
    }
    // 반복 횟수는 항상 동기화
    _loopExec.setRepeat(_loopRepeat);


    setState(() {
      _loopRemaining = _loopExec.remaining;
    });
    _wf.loopRepeat.value = _loopRepeat;

    _logSoTScreen(
      'APPLY_SIDECAR (loop/startCue restored)',
      loopA: _loopA,
      loopB: _loopB,
      startCue: _startCue,
    );

    if (posMs > 0) {
      final d = Duration(milliseconds: posMs);

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final dur = _effectiveDuration;
        if (dur != Duration.zero && d < dur) {
          await _engineSeekFromScreen(d);
        }
      });
    }

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

  void _startPosWatchdog() {
    _posWatchdog?.cancel();
    const period = Duration(seconds: 1);

    int steadyTicks = 0;
    bool reportedInThisSpan = false;
    Duration last = Duration.zero;

    _posWatchdog = Timer.periodic(period, (_) {
      if (!mounted || _isDisposing) return;

      final playing = EngineApi.instance.isPlaying;
      final current = _position;

      // 위치가 바뀌면 → 새 구간 시작
      if (current != last) {
        last = current;
        steadyTicks = 0;
        reportedInThisSpan = false;
        return;
      }

      // 위치는 그대로인데, 재생 중이 아니면 → 정지 상태이므로 무시
      if (!playing) {
        return;
      }

      // 재생 중 + 위치가 1초 이상 동일할 때 카운트
      steadyTicks++;

      // 5초 동안 그대로일 때 한 번만 로그
      if (!reportedInThisSpan && steadyTicks >= 5) {
        debugPrint(
          '[SMP] position steady 5s while playing (pos=${current.inMilliseconds}ms)',
        );
        _logSoTScreen('WATCHDOG steady 5s', pos: current);
        reportedInThisSpan = true;
      }
    });
  }


  Future<void> _openMedia() async {
    await EngineApi.instance.load(
      path: widget.mediaPath,
      onDuration: (d) {
        final engineDuration = d;
        final waveDuration = _wf.duration.value;

        final safeDuration = engineDuration > Duration.zero
            ? engineDuration
            : (waveDuration > Duration.zero ? waveDuration : Duration.zero);

        setState(() {
          _duration = safeDuration;
          _normalizeTimedState();
        });

        _wf.setDuration(safeDuration);
        _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
        _wf.setStartCue(_startCue);

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

  void _requestSave({bool saveMemo = true}) {
    if (_isDisposing) return;

    _saver.schedule(() async {
      if (_isDisposing) return;
      await _saveEverything(saveMemo: saveMemo);
    });
  }

  Future<void> _saveEverything({bool saveMemo = true}) async {
    // dispose 중에도 마지막 flush 저장은 허용해야 하므로
    // 여기서는 _isDisposing 으로 early-return 하지 않는다.

    // 메모 동기화 중일 때는 DB memo만 막고, sidecar는 계속 저장한다.
    if (_hydratingMemo && saveMemo) {
      saveMemo = false;
    }

    final now = DateTime.now();

    // 저장 직전에 한번 더 정규화
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
      // 1) 사이드카 저장
      await SidecarSyncDb.instance.save(map, debounce: false);

      // 2) 메모는 hydration 중이 아닐 때만 DB에 반영
      if (saveMemo && !_hydratingMemo) {
        await LessonMemoSync.instance.upsertMemo(
          studentId: widget.studentId,
          dateISO: _todayDateStr,
          memo: _notes,
        );
      }

      // 3) 가능하면 즉시 업로드 시도
      await SidecarSyncDb.instance.tryUploadNow();

      // 🔒 dispose 중에는 setState 금지
      final canTouchUi = mounted && !_isDisposing;
      if (canTouchUi) {
        setState(() {
          _saveStatus = SaveStatus.saved;
          _lastSavedAt = now;
          _pendingRetryCount = 0;
        });
      }
    } catch (_) {
      // UI 업데이트는 dispose 중엔 하지 않음
      if (!mounted || _isDisposing) return;
      setState(() => _saveStatus = SaveStatus.failed);
    }
  }


  Future<void> _startHoldFastForward() async {
    await EngineApi.instance.ffrw.startForward(
      startCue: Duration.zero,
      loopA: null,
      loopB: null,
      loopOn: false,
    );
    setState(() {});
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

  Duration _clamp(Duration x, Duration min, Duration max) {
    if (x < min) return min;
    if (x > max) return max;
    return x;
  }

  Duration get _effectiveDuration {
    if (_duration > Duration.zero) return _duration;
    if (_wf.duration.value > Duration.zero) return _wf.duration.value;
    return Duration.zero;
  }

  /// WaveformPanel(드래그/핸들/더블탭)에서 올라오는 루프 설정 요청
  ///
  /// R1. 루프 영역 있으면 → loopOn 무조건 true
  /// R2. 루프 영역 있으면 → StartCue 항상 A에 붙는다
  /// R3. 드래그로 루프 영역 만든 순간 A/B 정렬 + loopOn=true + StartCue=A
  /// R4. 루프 영역 해제(null,null) 시 → 루프 OFF + 영역 제거
  void _onLoopSetFromPanel(Duration? a, Duration? b) {
    if (_isDisposing) return;

    final dur = _effectiveDuration;

    Duration? newA = a;
    Duration? newB = b;

    // duration 범위 안으로 클램프
    if (dur > Duration.zero) {
      if (newA != null) newA = _clamp(newA, Duration.zero, dur);
      if (newB != null) newB = _clamp(newB, Duration.zero, dur);
    }

    // 유효성 검사
    final bool hasLoop = newA != null && newB != null && newA! < newB!;
    if (!hasLoop) {
      // 👉 루프 해제 요청으로 처리 (R4에서 "기존 루프 삭제" 케이스 포함)
      setState(() {
        _loopA = null;
        _loopB = null;
        _loopEnabled = false;
      });

      // LoopExecutor 비활성화
      _loopExec.setLoopEnabled(false);

      // WaveformController도 루프 영역 제거
      _wf.setLoop(a: null, b: null, on: false);

      _logSoTScreen('LOOP_CLEAR_FROM_PANEL');
      _requestSave(saveMemo: false);
      return;
    }

    final aa = newA!;
    final bb = newB!;

    // 👉 R1/R2/R3: 유효한 루프 영역 → loopOn=true, StartCue=A
    final newStartCue = _normalizeStartCueForLoop(aa);

    setState(() {
      _loopA = aa;
      _loopB = bb;
      _loopEnabled = true; // R1: 영역 있으면 항상 ON
      _startCue = newStartCue; // R2: StartCue = A
    });

    // LoopExecutor에 범위/상태 반영
    _loopExec.setA(aa);
    _loopExec.setB(bb);
    _loopExec.setLoopEnabled(true);

    // WaveformController에 실제 루프/StartCue 반영
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    _logSoTScreen(
      'LOOP_SET_FROM_PANEL',
      loopA: _loopA,
      loopB: _loopB,
      startCue: _startCue,
    );
    _requestSave(saveMemo: false);
  }

  /// WaveformPanel(클릭/드래그 시작점 등)에서 올라오는 StartCue 후보
  ///
  /// - 루프 없으면: 단순히 0~duration 안으로만 클램프
  /// - 루프 있으면: R2에 따라 항상 루프 안, 필요 시 A로 스냅
  void _onStartCueFromPanel(Duration candidate) {
    if (_isDisposing) return;

    final fixed = _normalizeStartCueForLoop(candidate);
    if (fixed == _startCue) {
      // 변경 없으면 로그/저장 생략
      return;
    }

    setState(() {
      _startCue = fixed;
    });

    _wf.setStartCue(_startCue);

    _logSoTScreen('START_CUE_FROM_PANEL', startCue: _startCue);
    _requestSave(saveMemo: false);
  }


  void _normalizeTimedState() {
    if (_isNormalizingTimedState) {
      _logSoTScreen('NORMALIZE_TIMED_STATE_SKIP (reentrant)', pos: _position);
      return;
    }

    _isNormalizingTimedState = true;
    try {
      final dur = _effectiveDuration;

      Duration? newA = _loopA;
      Duration? newB = _loopB;
      bool newLoopOn = _loopEnabled;
      Duration newStartCue = _startCue;

      if (dur <= Duration.zero) {
        if (newA != null && newA < Duration.zero) {
          newA = Duration.zero;
        }
        if (newB != null && newB < Duration.zero) {
          newB = Duration.zero;
        }
        if (newStartCue < Duration.zero) {
          newStartCue = Duration.zero;
        }
      } else {
        if (newA != null) {
          newA = _clamp(newA, Duration.zero, dur);
        }
        if (newB != null) {
          newB = _clamp(newB, Duration.zero, dur);
        }

        bool loopValid = false;
        if (newA != null && newB != null && newA < newB) {
          loopValid = true;
        } else {
          newA = null;
          newB = null;
        }
        newLoopOn = loopValid && newLoopOn;

        var sc = newStartCue;
        if (sc < Duration.zero) sc = Duration.zero;
        if (sc > dur) sc = dur;

        if (newA != null && newB != null && newA < newB) {
          final a = _clamp(newA, Duration.zero, dur);
          final b = _clamp(newB, Duration.zero, dur);
          if (sc < a || sc > b) {
            sc = a;
          }
        }
        newStartCue = sc;

        _loopRepeat = _loopRepeat.clamp(0, 200);
      }

      final loopChanged =
          newA != _loopA || newB != _loopB || newLoopOn != _loopEnabled;
      final startCueChanged = newStartCue != _startCue;
      final durationChanged = dur != _lastNormDuration;

      _loopA = newA;
      _loopB = newB;
      _loopEnabled = newLoopOn;
      _startCue = newStartCue;

      if (loopChanged || durationChanged) {
        _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
      }
      if (startCueChanged || durationChanged) {
        _wf.setStartCue(_startCue);
      }

      if (loopChanged || startCueChanged || durationChanged) {
        _lastNormLoopA = _loopA;
        _lastNormLoopB = _loopB;
        _lastNormLoopEnabled = _loopEnabled;
        _lastNormStartCue = _startCue;
        _lastNormDuration = dur;

        _logSoTScreen(
          'NORMALIZE_TIMED_STATE',
          pos: _position,
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
        );
      }
    } finally {
      _isNormalizingTimedState = false;
    }
  }

  Future<void> _engineSeekFromScreen(
    Duration target, {
    bool? resumePlaying,
  }) async {
    if (_isDisposing) return;

    final dur = _effectiveDuration;
    var clampedTarget = target;
    if (dur > Duration.zero) {
      clampedTarget = _clamp(target, Duration.zero, dur);
    } else if (clampedTarget < Duration.zero) {
      clampedTarget = Duration.zero;
    }

    if (_seekInFlight && _seekInFlightTarget == clampedTarget) {
      _logSoTScreen(
        'SEEK_SCREEN_SKIP (in-flight same target)',
        pos: clampedTarget,
      );
      return;
    }

    _seekInFlight = true;
    _seekInFlightTarget = clampedTarget;

    try {
      await EngineApi.instance.seekUnified(
        clampedTarget,
        startCue: _startCue,
        loopA: _loopA,
        loopB: _loopB,
      );
    } finally {
      _seekInFlight = false;
    }

    if (resumePlaying == true && !_isDisposing) {
      await _enginePlayFromScreen();
    }
  }

  Future<void> _engineSeekAndMaybeResumeFromScreen(Duration target) async {
    if (_isDisposing) return;

    final wasPlaying = EngineApi.instance.isPlaying;
    await _engineSeekFromScreen(target, resumePlaying: wasPlaying);
  }

  Future<void> _enginePlayFromScreen() async {
    if (_isDisposing) return;

    if (_playInFlight) {
      _logSoTScreen('PLAY_SCREEN_SKIP (in-flight)');
      return;
    }

    _playInFlight = true;
    try {
      await EngineApi.instance.play();
    } finally {
      _playInFlight = false;
    }
  }

  Future<void> _engineSpaceFromScreen() async {
    if (_isDisposing) return;

    final now = DateTime.now();

    if (_spaceInFlight) {
      _logSoTScreen('SPACE_SCREEN_SKIP (in-flight)');
      return;
    }

    if (_lastSpaceInvokedAt != null &&
        now.difference(_lastSpaceInvokedAt!) <
            const Duration(milliseconds: 150)) {
      _logSoTScreen('SPACE_SCREEN_SKIP (debounced)');
      return;
    }

    _spaceInFlight = true;
    _lastSpaceInvokedAt = now;

    try {
      await EngineApi.instance.spaceBehavior(
        _startCue,
        loopA: _loopA,
        loopB: _loopB,
        loopOn: _loopEnabled,
      );
    } finally {
      _spaceInFlight = false;
    }
  }

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
        onPlayFromStartOrPause: () => _engineSpaceFromScreen(),
        onToggleLoop: () {
          _loopToggleMain(!_loopEnabled);
        },
        onLoopASet: () => _loopSetA(_wf.position.value),
        onLoopBSet: () => _loopSetB(_wf.position.value),
        onMarkerAdd: _addMarker,
        onMarkerJump: (i1based) => _jumpToMarkerIndex(i1based - 1),
        onMarkerPrev: () => _jumpPrevNextMarker(next: false),
        onMarkerNext: () => _jumpPrevNextMarker(next: true),
        onZoom: (zoomIn) {
          final delta = zoomIn ? 1.10 : 0.90;
          _gestures.zoomAt(cursorFrac: 0.5, factor: delta);
        },
        onZoomReset: _gestures.zoomReset,
        onPitchNudge: _pitchDelta,
        onSpeedPreset: _setSpeed,
        onSpeedNudge: _nudgeSpeed,
        onKeyEvent: _onKeyEvent,
        child: Scaffold(
          appBar: AppBar(
            title: Text('스마트 미디어 플레이어 — $title'),
            actions: [
              ValueListenableBuilder<DateTime?>(
                valueListenable: SidecarSyncDb.instance.pendingUploadAtNotifier,
                builder: (ctx, pendingAt, child) {
                  final hasPending = pendingAt != null;
                  return AnimatedSwitcher(
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
                                gestures: _gestures, 
                                onStateDirty: () => _requestSave(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          SmpTransportBar(
                            position: _wf.position.value,
                            duration: _wf.duration.value,
                            isPlaying: EngineApi.instance.isPlaying,
                            fmt: _fmt,
                            onPlayPause: () => _engineSpaceFromScreen(),
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

  static const List<LoopPresetItem> _loopPresets = [
    LoopPresetItem('1마디 · 50회', 50),
    LoopPresetItem('2마디 · 30회', 30),
    LoopPresetItem('4마디 · 20회', 20),
    LoopPresetItem('8마디 · 12회', 12),
  ];

  Duration _computeStartCueFromLoopOrPos(Duration fallbackPos) {
    Duration candidate = fallbackPos;

    if (_loopA != null && _loopB != null) {
      candidate = _loopA! <= _loopB! ? _loopA! : _loopB!;
    } else if (_loopA != null) {
      candidate = _loopA!;
    } else if (_loopB != null) {
      candidate = _loopB!;
    }

    return _normalizeStartCueForLoop(candidate);
  }

  void _loopToggleMain(bool on) {
    _loopExec.setLoopEnabled(on);

    final newOn = _loopExec.loopOn;
    _loopEnabled = newOn;

    // 🔹 Waveform 영역의 루프 하이라이트도 즉시 동기화
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);

    setState(() {});
    _requestSave();

    _logSoTScreen('LOOP_TOGGLE on=$newOn');
  }


  void _loopSetA(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    // Loop A 설정 + StartCue 동기화
    setState(() {
      _loopA = clamped;
      _startCue = _normalizeStartCueForLoop(clamped);
    });

    // 실행기 반영
    _loopExec.setA(clamped);

    // WF 반영
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    _requestSave();
    _logSoTScreen('LOOP_SET_A_KEY', loopA: _loopA, startCue: _startCue);
  }


  void _loopSetB(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    // A가 없으면 → A를 먼저 만든다
    if (_loopA == null) {
      _loopSetA(clamped);
      return;
    }

    Duration a = _loopA!;
    Duration b = clamped;

    // A/B 정렬
    if (b < a) {
      final tmp = a;
      a = b;
      b = tmp;
    }

    // 🔥 드래그 경로와 동일한 R1~R3 규칙 적용
    // 1) 루프 영역 있으면 loopOn=true
    // 2) StartCue = A
    // 3) LoopExecutor + WF에 모두 동기화
    _onLoopSetFromPanel(a, b);

    _logSoTScreen('LOOP_SET_B_KEY', loopA: a, loopB: b, startCue: _startCue);
  }


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

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v.clamp(0.5, 1.5));
    await EngineApi.instance.setTempo(_speed);
    _requestSave();
  }

  Future<void> _nudgeSpeed(int deltaPercent) async {
    final step = deltaPercent / 100.0;
    await _setSpeed(_speed + step);
  }

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

  Future<void> _setVolume(int v) async {
    setState(() => _volume = v.clamp(0, 150));
    await EngineApi.instance.setVolume(_volume / 100.0);
    _requestSave();
  }

  Future<void> _nudgeVolume(int delta) async {
    await _setVolume(_volume + delta);
  }

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
  
    /// 🔹 WaveformPanel(말풍선 드래그)에서 마커 시간이 바뀐 경우
  /// - WaveformController.markers(list)를 기준으로 `_markers`를 재구성
  /// - label 기준으로 기존 MarkerPoint를 최대한 재사용해서 color/repeat 유지
  void _onMarkersChangedFromWaveform(List<WfMarker> wfMarkers) {
    setState(() {
      // 기존 MarkerPoint들을 복사해서 label 매칭용으로 사용
      final remaining = List<MarkerPoint>.from(_markers);
      final List<MarkerPoint> next = [];

      for (final wm in wfMarkers) {
        // 1) 같은 label 가진 기존 MarkerPoint를 먼저 찾는다
        final idx = remaining.indexWhere((mp) => mp.label == wm.label);
        if (idx >= 0) {
          final mp = remaining[idx];
          // t는 mutable 이라고 가정 (MarkerPoint.t now mutable)
          mp.t = wm.time;
          next.add(mp);
          remaining.removeAt(idx);
        } else {
          // 2) 없으면 새로 하나 만든다 (color/repeat는 기본값)
          next.add(MarkerPoint(wm.time, wm.label));
        }
      }

      _markers
        ..clear()
        ..addAll(next);
    });

    _logSoTScreen('MARKERS_FROM_WAVEFORM_SYNC', pos: _position);
    // 저장 트리거는 WaveformPanel.onStateDirty → _requestSave()가 이미 처리 중이라
    // 여기서 다시 _requestSave()를 부를 필요는 없다 (중복 방지 차원에서 생략).
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

    Future<void> _jumpToMarkerIndex(int index) async {
    if (index < 0 || index >= _markers.length) return;
    final m = _markers[index];

    // 1) 목표 지점 (클램프)
    final rawTarget = m.t;
    final target = _normalizeMarkerTarget(rawTarget);

    final isPlaying = EngineApi.instance.isPlaying;

    setState(() {
      // 🔹 정지 상태 + 루프 OFF일 때는
      //    "이 마커가 현재 연습 포인트"가 되도록 StartCue를 같이 맞춰준다.
      if (!isPlaying && !_loopEnabled) {
        _startCue = _normalizeStartCueForLoop(target);
        _wf.setStartCue(_startCue);
      }

      // 🔹 루프 켜져 있는데 점프 지점이 루프 밖이면 → 루프 OFF
      if (_loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (a < b && (target < a || target > b)) {
          _loopEnabled = false;
          _loopExec.setLoopEnabled(false);
          _wf.setLoop(a: _loopA, b: _loopB, on: false);
        }
      }

      // 🔹 마커 네비게이션 커서도 최신 위치로 업데이트
      _markerNavCursor = target;
    });

    // 2) 엔진 시킹 (정지/재생 상태에 따라 resume 여부 자동 결정)
    await _engineSeekAndMaybeResumeFromScreen(target);

    // 3) 위치만 저장
    _requestSave(saveMemo: false);

    _logSoTScreen('MARKER_JUMP idx=$index', pos: target, startCue: _startCue);
  }




    Future<void> _jumpPrevNextMarker({required bool next}) async {
    if (_markers.isEmpty) return;

    // 🔹 기준 위치: 마커 네비게이션 커서가 있으면 그걸 우선 사용
    //    - Alt+←/→를 연속 입력할 때, "시간이 조금 흘렀다"는 이유로
    //      같은 마커에 계속 머무는 현상을 줄이기 위함.
    final base = _markerNavCursor ?? _position;

    // 시간 순으로 정렬된 리스트 기준으로 이전/다음 후보 탐색
    final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));

    MarkerPoint? candidate;
    if (next) {
      for (final m in sorted) {
        if (m.t > base) {
          candidate = m;
          break;
        }
      }
      candidate ??= sorted.first; // 끝에서 더 가면 처음으로 래핑
    } else {
      for (final m in sorted.reversed) {
        if (m.t < base) {
          candidate = m;
          break;
        }
      }
      candidate ??= sorted.last; // 처음에서 더 가면 끝으로 래핑
    }

    final rawTarget = candidate.t;
    final target = _normalizeMarkerTarget(rawTarget);
    final isPlaying = EngineApi.instance.isPlaying;

    setState(() {
      // 🔹 정지 상태 + 루프 OFF일 때는
      //    "이 마커가 현재 연습 포인트"가 되도록 StartCue를 같이 맞춰준다.
      if (!isPlaying && !_loopEnabled) {
        _startCue = _normalizeStartCueForLoop(target);
        _wf.setStartCue(_startCue);
      }

      // 🔹 루프 켜져 있고, 점프 지점이 루프 밖이면 → 루프 OFF
      if (_loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (a < b && (target < a || target > b)) {
          _loopEnabled = false;
          _loopExec.setLoopEnabled(false);
          _wf.setLoop(a: _loopA, b: _loopB, on: false);
        }
      }

      // 🔹 네비게이션 커서 업데이트 (다음 Alt+←/→의 기준이 됨)
      _markerNavCursor = target;
    });

    // 재생 위치만 이동
    await _engineSeekAndMaybeResumeFromScreen(target);
    _requestSave(saveMemo: false);

    _logSoTScreen(
      next ? 'MARKER_NEXT' : 'MARKER_PREV',
      pos: target,
      startCue: _startCue,
    );
  }


  void _reorderMarker(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _markers.length) return;

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

  Duration _normalizeStartCueForLoop(Duration candidate) {
    final dur = _effectiveDuration;

    Duration sc = candidate;
    if (dur > Duration.zero) {
      sc = _clamp(sc, Duration.zero, dur);
    } else if (sc < Duration.zero) {
      sc = Duration.zero;
    }

    if (_loopA == null || _loopB == null) {
      return sc;
    }

    final a = _loopA!;
    final b = _loopB!;

    if (dur <= Duration.zero || a >= b) {
      return sc;
    }

    final aClamped = _clamp(a, Duration.zero, dur);
    final bClamped = _clamp(b, Duration.zero, dur);

    if (sc < aClamped || sc > bClamped) {
      return aClamped;
    }

    return sc;
  }

  // 🔹 마커 점프 시 사용할 시킹 타겟 정규화 (0 ~ duration 안으로만 클램프)
  Duration _normalizeMarkerTarget(Duration candidate) {
    final dur = _effectiveDuration;

    Duration t = candidate;

    if (dur > Duration.zero) {
      t = _clamp(t, Duration.zero, dur);
    } else if (t < Duration.zero) {
      t = Duration.zero;
    }

    // 🔥 마커 점프는 단순히 재생 위치만 이동한다.
    // 루프 안/밖 여부, StartCue 재설정 여부는 호출부에서 별도로 처리한다.
    return t;
  }

}
