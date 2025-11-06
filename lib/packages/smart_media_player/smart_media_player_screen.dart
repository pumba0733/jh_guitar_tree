// lib/packages/smart_media_player/smart_media_player_screen.dart
// v3.07.2 + A~C 패치 | Storage sync + Lessons Realtime 양방향 메모 + XSC 완전 제거
// Patch: remove auto-play on E/D & waveform drag selection, playback completed → auto play from startCue
// UI v3.08-skyblue: AppSection + AppMiniButton + PresetSquare(50~100) + 라인정렬 + 구분선
// 추가 패치(A~C):
//  A) 앱 라이프사이클(Inactive/Paused)에서 즉시 flush 저장
//  B) onSeek 연타 시 저장 과다 완화(포지션 변화량/시간 기준으로 저장)
//  C) pendingUploadAt 감지하여 AppBar에 "업로드 대기중" 배지 표시

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
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// NEW
import 'package:guitartree/packages/smart_media_player/waveform/system/waveform_system.dart'
    show WaveformController, WfMarker;

import 'waveform/system/waveform_panel.dart';
import 'waveform/waveform_tuning.dart';
import 'models/marker_point.dart';
import 'sync/sidecar_sync_db.dart';
import 'audio/soundtouch_audio_chain.dart' as ac;
import 'utils/debounced_saver.dart';
import 'video/sticky_video_overlay.dart';

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

  // ==== Zoom constants (one source of truth) ====
  static const double _zoomMax = 50.0; // 최대 50x
  static const double _minViewWidth = 1.0 / _zoomMax; // viewWidth 하한 (50x에 해당)

  @override
  State<SmartMediaPlayerScreen> createState() => _SmartMediaPlayerScreenState();
}

// A~C 패치: WidgetsBindingObserver 믹스인 추가
class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen>
    with WidgetsBindingObserver {
  late final DebouncedSaver _saver;
  // media_kit
  late final Player _player;
  VideoController? _videoCtrl;
  bool _isVideo = false;
  Timer? _applyDebounce;

  // 구독
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  
  bool _hydratingMemo = false; // 외부 주입 중 플래그

  // 포커스
  final FocusNode _focusNode = FocusNode(debugLabel: 'SMPFocus');

  // [PIP] 스크롤 컨트롤러 (영상 오버레이 축소/고정)
  final ScrollController _scrollCtl = ScrollController();

  final WaveformController _wf = WaveformController();

  // 컨트롤러 리스너 핸들
  VoidCallback? _loopOnListener;
  VoidCallback? _markersListener;

  // 파라미터
  double _speed = 1.0;
  int _pitchSemi = 0;

  // 🔊 볼륨(0~150)
  int _volume = 100;
  final bool _muted = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;
  int _loopRepeat = 0; // 0=∞
  int _loopRemaining = -1;

  DateTime? _seekingGuardUntil;
  void _beginSeekGuard([int ms = 60]) {
    _seekingGuardUntil = DateTime.now().add(Duration(milliseconds: ms));
  }

  bool get _isSeekGuardActive =>
      _seekingGuardUntil != null &&
      DateTime.now().isBefore(_seekingGuardUntil!);

  void _onScrollTick() {
    if (!mounted) return;
    setState(() {}); // 스크롤 오프셋 변화에 맞춰 오버레이 재계산
  }
  static const double _holdFastRate = 4.0;
  // 시작점
  Duration _startCue = Duration.zero;
  
  bool _isDisposing = false; // ✅ dispose 중 가드
  VoidCallback? _saverListener; // ✅ 리스너 핸들 보관

  // 마커
  final List<MarkerPoint> _markers = [];

  // 메모
  String _notes = '';
  late final TextEditingController _notesCtl;
  bool _notesInitApplying = true;

  Timer? _afWatchdog;
  String _lastAfGot = '';
  final _lastAfWanted = '';
 
  Future<void> _logAf([String tag = '']) async {
    try {
      final dynamic plat = _player.platform;
      final got = await plat?.getProperty('af');
      if ('$got' != _lastAfGot) {
        _lastAfGot = '$got';
        debugPrint('[AF$tag] now="$got"');
        // 기대했던 체인과 다르면 빨간 플래그
        if (_lastAfWanted.isNotEmpty && _lastAfGot != _lastAfWanted) {
          debugPrint(
            '[AF OVERRIDDEN] expected="$_lastAfWanted"  got="$_lastAfGot"',
          );
        }
      }
    } catch (_) {}
  }

  // 자동 저장
  Timer? _saveDebounce;

  // ✅ 저장 상태(공용 UI 연동)
  SaveStatus _saveStatus = SaveStatus.idle;
  DateTime? _lastSavedAt;
  int _pendingRetryCount = 0;

  // B 패치: 위치 변경 저장 최적화용
  int _lastSavedPosMs = -1;

  // 뷰포트
  double _viewStart = 0.0;
  double _viewWidth = 1.0;

  // 워치독
  Timer? _posWatchdog;

  // 2x 정/역재생(시뮬)용
  Timer? _reverseTick;
  bool _holdFastForward = false;
  bool _holdFastReverse = false;

  bool _ffStartedFromPause = false;
  bool _frStartedFromPause = false;

  // 오늘 날짜
  late final String _todayDateStr = () {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    return d0.toIso8601String().split('T').first;
  }();

  // ===== 사이드카 경로(로컬) =====
  Future<String> _resolveLocalSidecarPath() async {
   // DB판은 캐시 파일이 선택 사항. 표시용으로만 경로 구성.
    final wsRoot = Directory(widget.studentDir).parent.parent.path;
    final cacheDir = p.join(wsRoot, '.cache', 'sidecar_local');
    final name = '${widget.studentId}_${widget.mediaHash}.json';
    return p.join(cacheDir, name);
  }

  String get _cacheDir {
    final wsRoot = Directory(widget.studentDir).parent.parent.path;
    return p.join(wsRoot, '.cache');
  }

  @override
  void initState() {
    super.initState();
    // A 패치: 라이프사이클 옵저버 등록
    WidgetsBinding.instance.addObserver(this);

    // ✅ 트랜스크라이브 톤(VisualExact + Signed) 기본 적용
    WaveformTuning.I.applyPreset(WaveformPreset.transcribeLike);
    WaveformTuning.I
      ..visualExact = true
      ..useSignedAmplitude = true;

    _saver = DebouncedSaver(delay: const Duration(milliseconds: 800));
    MediaKit.ensureInitialized();

    _notesCtl = TextEditingController(text: _notes);
    _scrollCtl.addListener(_onScrollTick);

    _detectIsVideo();
    // 안전 가드: ensureInitialized 중복 호출 무해
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    _player = Player();

    // === 컨트롤러 콜백 (패널 → 화면/플레이어) ===
    _wf.onLoopSet = (a, b) {
      setState(() {
        _loopA = a;
        _loopB = b;
        _loopEnabled = true; // 범위만 켬
      });
      // ⛔️ 자동 재생 제거 (요청사항)
      _wf.setLoop(a: _loopA, b: _loopB, on: true);
      _debouncedSave();
    };

    _wf.onStartCueSet = (t) {
      setState(() => _startCue = t);
      _debouncedSave();
    };

    _wf.onSeek = (d) async {
      _wf.updateFromPlayer(pos: d, dur: _duration);
      _wf.setStartCue(d);
      setState(() {
        _startCue = d;
        _position = d;
      });
      _beginSeekGuard();
      unawaited(_player.seek(d));

      // B 패치: 포지션 변화만 있을 때는 저장 빈도 낮춤
      _maybeSaveAfterPositionChange();
      return;
    };

    // 🔗 컨트롤러 → 화면 상태 동기화 리스너 바인딩
    _bindWaveformControllerListeners();

    if (_isVideo) _videoCtrl = VideoController(_player);

    // 🔧 비동기 초기화는 분리
    _initAsync();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    _initNotesAndSidecarSync(); // [SYNC]
    _subscribeLocalNotesBus(); // [NOTES BUS]
    _startPosWatchdog();

    // 초기 브릿지
    _wf.setViewport(start: _viewStart, width: _viewWidth);
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(_markers.map((m) => WfMarker(m.t, m.label)).toList());

    // 저장 상태 리스너
    _wf.onPause = () async {
      await _player.pause();
    };

    // ✅ 변경: 리스너를 변수에 보관 + mounted/_isDisposing 가드
    _saverListener = () {
      if (!mounted || _isDisposing) return;
      setState(() {
        _saveStatus = _saver.status;
        _lastSavedAt = _saver.lastSavedAt;
        _pendingRetryCount = _saver.pendingRetryCount;
      });
    };
    _saver.addListener(_saverListener!);
  }

  // A 패치: 앱 라이프사이클 변화 시 즉시 저장 한번 보장
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(
        _saver.flush(() async {
          await _saveSidecar(saveToDb: false);
        }),
      );
    }
  }

  void _bindWaveformControllerListeners() {
    _loopOnListener = () {
      final v = _wf.loopOn.value;
      if (!mounted) return;
      if (_loopEnabled != v) {
        setState(() => _loopEnabled = v);
        _debouncedSave();
      }
    };
    _wf.loopOn.addListener(_loopOnListener!);

    _markersListener = () {
      final list = _wf.markers.value;
      if (!mounted) return;
      final byLabel = <String, MarkerPoint>{};
      for (final m in _markers) {
        byLabel[m.label] = m;
      }
      final rebuilt = <MarkerPoint>[];
      for (final w in list) {
        final hit = byLabel[w.label ?? ''];
        if (hit != null) {
          hit.t = w.time;
          rebuilt.add(hit);
        } else {
          rebuilt.add(MarkerPoint(w.time, w.label ?? ''));
        }
      }
      setState(() {
        _markers
          ..clear()
          ..addAll(rebuilt..sort((a, b) => a.t.compareTo(b.t)));
      });
      _debouncedSave();
    };
    _wf.markers.addListener(_markersListener!);
  }

  Future<void> _initAsync() async {
    await _openMedia();
    _durSub = _player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
      _normalizeLoopOrder();
      _wf.updateFromPlayer(pos: _position, dur: d);
    });
    return;
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
    _debouncedSave(saveToDb: false);
  }

  void _subscribeLessonMemoRealtime() {
    final today = _todayDateStr;
    LessonMemoSync.instance.subscribeRealtime(
      studentId: widget.studentId,
      dateISO: today,
      onMemoChanged: (memo) {
        if (memo != _notes && mounted) {
          _hydratingMemo = true;
          setState(() {
            _notes = memo;
            _notesCtl.text = memo;
          });
          _saveSidecar(saveToDb: false);
          Future.delayed(
            const Duration(milliseconds: 50),
            () => _hydratingMemo = false,
          );
        }
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
      _saveSidecar(saveToDb: false);
      Future.delayed(
        const Duration(milliseconds: 50),
        () => _hydratingMemo = false,
      );
    });
  }

  @override
  void dispose() {
    _isDisposing = true;
    _afWatchdog?.cancel();
    _afWatchdog = null;
    // 1) 가장 먼저 saver 리스너 해제
    if (_saverListener != null) {
      _saver.removeListener(_saverListener!);
      _saverListener = null;
    }

    // 2) flush() 호출 금지 — notify가 터져서 크래시 유발함
    //    대신 실제 저장만 1회(예외 무시)
    try {
      unawaited(_saveSidecar(saveToDb: false));
    } catch (_) {}

    // 3) saver 자체 dispose
    _saver.dispose();

    // 이하 기존 dispose 그대로…
    SidecarSyncDb.instance.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _reverseTick?.cancel();
    _player.dispose();
    _notesCtl.dispose();
    _focusNode.dispose();
    _posWatchdog?.cancel();
    _scrollCtl.removeListener(_onScrollTick);
    _scrollCtl.dispose();
    LessonMemoSync.instance.dispose();
    if (_loopOnListener != null) _wf.loopOn.removeListener(_loopOnListener!);
    if (_markersListener != null) _wf.markers.removeListener(_markersListener!);
    _applyDebounce?.cancel();
    super.dispose();
  }

  void _applySidecarMap(Map<String, dynamic> m) {
    final a = (m['loopA'] ?? 0);
    final b = (m['loopB'] ?? 0);
    final sp = (m['speed'] ?? 1.0);
    final posMs = (m['positionMs'] ?? 0);
    final mk = (m['markers'] as List?)?.cast<dynamic>() ?? const [];
    final ps = (m['pitchSemi'] ?? 0);
    final rpRaw = (m['loopRepeat'] ?? 0);
    final sc = (m['startCueMs'] ?? 0);
    final notes = (m['notes'] as String?) ?? '';
    final vol = (m['volume'] ?? 100);

    setState(() {
      _loopA = (a is int && a > 0) ? Duration(milliseconds: a) : null;
      _loopB = (b is int && b > 0) ? Duration(milliseconds: b) : null;
      final loopOnWant = (m['loopOn'] ?? false) == true;
      _loopEnabled =
          loopOnWant && _loopA != null && _loopB != null && _loopA! < _loopB!;
      _speed = (sp as num).toDouble().clamp(0.5, 1.5);
      _loopRepeat = (rpRaw as num).toInt().clamp(0, 200);
      _loopRemaining = -1;
      _pitchSemi = (ps as num).toInt().clamp(-7, 7);
      _startCue = _clamp(
        Duration(milliseconds: (sc as num).toInt()),
        Duration.zero,
        _duration,
      );
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
    });

    if (posMs is num && posMs > 0) {
      final d = Duration(milliseconds: posMs.toInt());
      if (_duration != Duration.zero && d < _duration) {
        unawaited(_seekBoth(d));
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (_duration != Duration.zero && d < _duration) {
            await _seekBoth(d);
          }
        });
      }
    }

    _normalizeLoopOrder();
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(
      _markers
          .map((e) => WfMarker.named(time: e.t, label: e.label, color: e.color))
          .toList(),
    );
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
            '[SMP] position steady 5s (playing=${_player.state.playing})',
          );
          silentTicks = 0;
        }
      } else {
        silentTicks = 0;
        last = _position;
      }
    });
  }

  void _detectIsVideo() {
    final ext = p.extension(widget.mediaPath).toLowerCase();
    _isVideo = const ['.mp4', '.mov', '.mkv', '.webm', '.avi'].contains(ext);
  }

  Future<void> _openMedia() async {
    try {
      final dynamic plat = _player.platform;

      // 비디오가 아니면 mpv에 vid=no 지정 (오디오 전용)
      if (!_isVideo) {
        await plat?.setProperty('vid', 'no');
      }

      // macOS 기본 출력 + 독점 모드 OFF + 자동 디바이스
      await plat?.setProperty('ao', 'coreaudio');
      await plat?.setProperty('audio-exclusive', 'no');
      await plat?.setProperty('audio-device', 'auto');

      // 필요하면 samplerate 고정(선택)
      // await plat?.setProperty('audio-samplerate', '48000');
    } catch (_) {
      // mpv platform 없거나 세팅 실패해도 재생은 계속 가게 그냥 무시
    }

    // 실제 미디어 열기 (자동 재생은 false, 플레이어 상태는 아래에서 따로 갱신)
    await _player.open(Media(widget.mediaPath), play: false);

    final st = _player.state;
    if (mounted) {
      setState(() {
        _position = st.position;
        _duration = st.duration;
      });
    }
    _wf.updateFromPlayer(pos: _position, dur: _duration);

    // 🔁 위치 스트림 구독: AB 루프 + 파형/슬라이더 연동
    _posSub = _player.stream.position.listen((pos) async {
      if (!mounted) return;

      // === AB 루프 재점프 ===
      if (_loopEnabled && _loopA != null && _loopB != null) {
        const eps = Duration(milliseconds: 8);
        final b = _loopB!;
        if (pos + eps >= b) {
          // 반복 횟수 모드일 때 카운트다운
          if (_loopRepeat > 0) {
            if (_loopRemaining == -1) {
              setState(() => _loopRemaining = _loopRepeat);
            }
            setState(() => _loopRemaining = (_loopRemaining - 1).clamp(0, 200));

            // 반복 다 썼으면 루프 해제 + 시작점으로 이동
            if (_loopRemaining == 0) {
              setState(() => _loopEnabled = false);
              _wf.setLoop(on: false);

              final ret = _startCue > Duration.zero ? _startCue : b;
              unawaited(_player.pause());
              unawaited(_player.seek(_clamp(ret, Duration.zero, _duration)));
              _debouncedSave();
              return;
            }
          }

          // 아직 반복 남았으면 A 지점으로 점프
          final a = _clamp(_loopA!, Duration.zero, _duration);
          unawaited(_player.seek(a));
          _wf.updateFromPlayer(pos: a, dur: _duration);
          setState(() => _position = a);
          return;
        }
      }

      // 시킹 가드 중이면 내부 seek로 인한 이벤트는 무시
      if (_isSeekGuardActive) return;

      _wf.updateFromPlayer(pos: pos, dur: _duration);
      setState(() => _position = pos);
    });

    // ▶️/⏸ 재생 상태 스트림
    _playingSub = _player.stream.playing.listen((_) {
      if (!mounted) return;
      setState(() {});
    });

    // ✅ 완료 스트림: 루프 / 시작점 처리
    _completedSub = _player.stream.completed.listen((done) async {
      if (!mounted || !done) return;

      // 루프 켜져 있으면 A로 돌아가서 계속 반복
      if (_loopEnabled && _loopA != null && _loopB != null) {
        final a = _clamp(_loopA!, Duration.zero, _duration);
        unawaited(_player.seek(a));
        unawaited(_player.play());
        return;
      }

      // ⛳️ 변경: 루프 OFF 상태에서 끝까지 재생되면 StartCue부터 자동 재생
      final a = _clamp(_startCue, Duration.zero, _duration);
      unawaited(_player.seek(a));
      unawaited(_player.play());
    });

    // 오디오 체인(SoundTouch 등) 적용
    await _applyAudioChain();
    await ac.SoundTouchAudioChain.instance.startFeedLoop();

    // 🔎 AF 감시: 400ms마다 mpv 'af' 체인 로그 출력 (디버그 용)
    _afWatchdog?.cancel();
    _afWatchdog = Timer.periodic(const Duration(milliseconds: 400), (_) {
      unawaited(_logAf());
    });
  }


  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Future<void> _applyAudioChain() async {
    debugPrint(
      '[SMP] _applyAudioChain speed=$_speed semi=$_pitchSemi vol=$_volume',
    );
    ac.SoundTouchAudioChain.instance.apply(
      _speed,
      _pitchSemi.toDouble(), // ✅ 명시적 double 변환
      _volume.toDouble(),
    );
  }


  Future<void> _applyAudioChainDebounced() async {
    if (_applyDebounce?.isActive ?? false) return; // ✅ 중복 방지
    _applyDebounce = Timer(const Duration(milliseconds: 150), () async {
      await _applyAudioChain();
    });
  }





  // === 템포/키/볼륨: 2줄 고정 레이아웃 (라벨/값(+프리셋 1줄) + 슬라이더 1줄)
  Widget _buildControlRow() {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      fontWeight: FontWeight.w700,
    );
    final valueStyle = theme.textTheme.labelLarge!;
    const presets = <double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0];

    final accent = const Color(0xFF81D4FA); // Sky-Mint Blend
    final inactive = accent.withValues(alpha: 0.25);

    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      activeTrackColor: accent,
      inactiveTrackColor: inactive,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.08),
    );

    Widget row(String label, String value, {Widget? trailing}) => SizedBox(
      height: 26, // 28 → 26
      child: Row(
        children: [
          Text(label, style: labelStyle),
          const SizedBox(width: 6),
          Text(value, style: valueStyle),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(child: trailing),
          ],
        ],
      ),
    );

    Widget presetStrip(double cur) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final v in presets) ...[
            PresetSquare(
              label: '${(v * 100).round()}',
              active: (v - cur).abs() < 0.011,
              onTap: () => _setSpeed(v),
              size: 32,
              height: 22,
              fontSize: 10, // 더 작게
            ),
            const SizedBox(width: 4), // 6 → 4
          ],
        ],
      ),
    );

    return AppSection(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                  '템포',
                  '${(_speed * 100).round()}%',
                  trailing: presetStrip(_speed),
                ),
                const SizedBox(height: 2), // 4 → 2
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '템포 -5%',
                        onPressed: () => _nudgeSpeed(-5),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _speed,
                          min: 0.5,
                          max: 1.5,
                          divisions: 100,
                          onChanged: (v) => _setSpeed(v),
                        ),
                      ),
                      IconButton(
                        tooltip: '템포 +5%',
                        onPressed: () => _nudgeSpeed(5),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
          const SizedBox(width: 12), // 14 → 12
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('키', '${_pitchSemi >= 0 ? '+' : ''}$_pitchSemi'),
                const SizedBox(height: 2),
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '-1 key',
                        onPressed: () => _pitchDelta(-1),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _pitchSemi.toDouble(),
                          min: -7,
                          max: 7,
                          divisions: 14,
                          onChanged: (v) => _setPitch(v.round()),
                        ),
                      ),
                      IconButton(
                        tooltip: '+1 key',
                        onPressed: () => _pitchDelta(1),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('볼륨', '$_volume%'),
                const SizedBox(height: 2),
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '볼륨 -5%',
                        onPressed: () => _nudgeVolume(-5),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _volume.toDouble(),
                          min: 0,
                          max: 150,
                          divisions: 150,
                          onChanged: (v) => _setVolume(v.round()),
                        ),
                      ),
                      IconButton(
                        tooltip: '볼륨 +5%',
                        onPressed: () => _nudgeVolume(5),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopTransportBar() {
    final theme = Theme.of(context);
    const w4 = SizedBox(width: 4);
    const w6 = SizedBox(width: 6);

    // 왼쪽: 시간 + 플레이 클러스터(되감기/재생/2x)
    final left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.28),
            ),
          ),
          child: Text(
            '${_fmt(_position)} / ${_fmt(_duration)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        w6,
        // 되감기 - 재생 - 2배속 (버튼 밀착)
        _HoldIconButton(
          icon: Icons.fast_rewind,
          onDown: _startHoldFastReverse,
          onUp: _stopHoldFastReverse,
        ),
        w4,
        IconButton(
          tooltip: _player.state.playing ? '일시정지' : '재생',
          onPressed: _spacePlayBehavior,
          icon: Icon(_player.state.playing ? Icons.pause : Icons.play_arrow),
          iconSize: 22,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        ),

        w4,
        _HoldIconButton(
          icon: Icons.fast_forward,
          onDown: _startHoldFastForward,
          onUp: _stopHoldFastForward,
        ),
      ],
    );

    // 중앙: 루프 묶음(가로 스크롤, 1줄)
    final centerLoop = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          AppMiniButton(
            compact: true,
            icon: Icons.playlist_add,
            iconSize: 22, // <- 아이콘 키움
            label: _loopA == null ? '루프 시작' : '루프 시작 ${_fmt(_loopA!)}',
            onPressed: () => _setLoopPoint(isA: true),
          ),
          w6,
          AppMiniButton(
            compact: true,
            icon: Icons.playlist_add_check,
            iconSize: 22, // <- 아이콘 키움
            label: _loopB == null ? '루프 끝' : '루프 끝 ${_fmt(_loopB!)}',
            onPressed: () => _setLoopPoint(isA: false),
          ),
          w6,
          Row(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('반복', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '선택한 A–B 구간을 반복 재생합니다',
                    child: Switch.adaptive(
                      value: _loopEnabled,
                      onChanged: (v) {
                        setState(() {
                          _loopEnabled = v;
                          _loopRemaining = (v && _loopRepeat > 0)
                              ? _loopRepeat
                              : -1;
                        });
                        _wf.setLoop(on: v);
                        _debouncedSave();
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),


              w4,
              SizedBox(
                height: 32,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 스텝퍼: -1
                    IconButton(
                      tooltip: '반복 -1',
                      onPressed: () => _changeLoopRepeat(-1),
                      onLongPress: () => _changeLoopRepeat(-5),
                      icon: const Icon(Icons.remove),
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                    ),
                    // 현재 값 표시(∞ 지원)
                    InkWell(
                      onTap: _promptLoopRepeatInput, // 탭 시 다이얼로그 오픈
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _fmtLoopRepeat(_loopRepeat),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),

                    // 스텝퍼: +1
                    IconButton(
                      tooltip: '반복 +1',
                      onPressed: () => _changeLoopRepeat(1),
                      onLongPress: () => _changeLoopRepeat(5),
                      icon: const Icon(Icons.add),
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                    ),
                    const SizedBox(width: 4),

                    // 프리셋 드롭다운 (1/2/4/8마디 권장 회수)
                    PopupMenuButton<int>(
                      tooltip: '반복 프리셋',
                      itemBuilder: (ctx) => [
                        for (final p in _loopPresets)
                          PopupMenuItem<int>(
                            value: p.repeats,
                            child: Text(p.label),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<int>(
                          value: 0,
                          child: Text('∞ (무한반복)'),
                        ),
                        const PopupMenuItem<int>(
                          value: -999,
                          child: Text('직접 입력…'),
                        ),
                      ],
                      onSelected: (v) async {
                        if (v == -999) {
                          final ctl = TextEditingController(
                            text: _loopRepeat.toString(),
                          );
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('반복횟수 입력 (0=∞)'),
                              content: TextField(
                                controller: ctl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  hintText: '0~200',
                                ),
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
                            final n =
                                int.tryParse(ctl.text.trim()) ?? _loopRepeat;
                            await _setLoopRepeatExact(n);
                          }
                        } else {
                          await _setLoopRepeatExact(v);
                        }
                      },
                      child: const Icon(Icons.more_horiz, size: 20),
                    ),
                  ],
                ),
              ),
              w4,
              Tooltip(
                message: _loopRepeat == 0
                    ? '무한 반복 (0=∞)'
                    : '현재 루프가 끝날 때까지 남은 반복 횟수입니다',
                child: _RemainingPill(
                  loopEnabled: _loopEnabled,
                  loopRepeat: _loopRepeat,
                  loopRemaining: _loopRemaining,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    // 오른쪽: 줌
    final rightZoom = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '줌 아웃',
              onPressed: () => _zoom(0.8),
              icon: const Icon(Icons.zoom_out),
              iconSize: 22,
              visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '줌 리셋',
              onPressed: _zoomReset,
              icon: const Icon(Icons.center_focus_strong),
              iconSize: 22,
              visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '줌 인',
              onPressed: () => _zoom(1.25),
              icon: const Icon(Icons.zoom_in),
              iconSize: 22,
              visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
            ),
          ],
        )

      ],
    );

    return AppSection(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: left,
            ),
            const SizedBox(width: 6),
            Expanded(child: Center(child: centerLoop)),
            const SizedBox(width: 6),
            rightZoom,
          ],
        ),
      ),
    );
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

  Future<void> _seekBoth(Duration d) async {
    await _player.seek(d);
  }

  // ===== B 패치: 포지션 변화 저장 완화 =====
  void _maybeSaveAfterPositionChange() {
    final cur = _position.inMilliseconds;
    final posDelta = (_lastSavedPosMs < 0)
        ? 999999
        : (cur - _lastSavedPosMs).abs();
    final stale = _lastSavedAt == null
        ? true
        : DateTime.now().difference(_lastSavedAt!) > const Duration(seconds: 3);
    // 조건: 500ms 이상 이동했거나, 마지막 저장 후 3초 지남
    if (posDelta >= 500 || stale) {
      _lastSavedPosMs = cur;
      _debouncedSave(saveToDb: false);
    }
  }

  // ===== 저장 =====
  Future<void> _saveSidecar({
    bool toast = false,
    bool saveToDb = true, 
  }) async {
    final now = DateTime.now();
    final map = {
      'studentId': widget.studentId,
      'mediaHash': widget.mediaHash,
      'speed': _speed,
      'pitchSemi': _pitchSemi,
      'loopA': _loopA?.inMilliseconds ?? 0,
      'loopB': _loopB?.inMilliseconds ?? 0,
      'loopOn': _loopEnabled,
      'loopRepeat': _loopRepeat, // 0=∞
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
      await SidecarSyncDb.instance.save(map, debounce: false);

      if (saveToDb && !_hydratingMemo) {
        unawaited(_saveLessonMemoToSupabase());
      }

      if (mounted) {
        setState(() {
          _saveStatus = SaveStatus.saved;
          _lastSavedAt = now;
          _pendingRetryCount = 0;
        });
      }

      if (toast && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('자동 저장됨')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveStatus = SaveStatus.failed);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('저장 실패: $e')));
    }
  }

  Future<void> _saveLessonMemoToSupabase() async {
    try {
      await LessonMemoSync.instance.upsertMemo(
        studentId: widget.studentId,
        dateISO: _todayDateStr,
        memo: _notes,
      );
    } catch (_) {}
  }

  void _debouncedSave({bool saveToDb = true}) {
    _saver.schedule(() async {
      await _saveSidecar(saveToDb: saveToDb);
    });
  }

  // ===== 2x 정/역재생(홀드) =====
  Future<void> _startHoldFastForward() async {
    if (_holdFastForward) return;
    _holdFastForward = true;

    if (!_player.state.playing) {
      _ffStartedFromPause = true;
      final d = _clamp(_startCue, Duration.zero, _duration);
      await _seekBoth(d);
      await _player.play();
    } else {
      _ffStartedFromPause = false;
    }
    await _player.setRate(_holdFastRate); // 3.0x
  }

  Future<void> _stopHoldFastForward() async {
    if (!_holdFastForward) return;
    _holdFastForward = false;
    if (_ffStartedFromPause) {
      await _player.pause();
    } else {
      await _applyAudioChainDebounced(); // 🔁 여기만 Debounce
    }
    _ffStartedFromPause = false;
  }


  void _startHoldFastReverse() {
    if (_holdFastReverse) return; // 🔧 버그픽스: 기존에는 if (!_) return 이라 항상 리턴됨
    _holdFastReverse = true;
    _reverseTick?.cancel();

    _frStartedFromPause = !_player.state.playing;
    if (_frStartedFromPause) {
      unawaited(_player.play());
      unawaited(_player.setRate(1.0));
    }

    // 약 3x 체감 역재생: 50ms마다 150ms씩 뒤로 점프
    const period = Duration(milliseconds: 50);
    const backStep = Duration(milliseconds: 150);

    _reverseTick = Timer.periodic(period, (_) async {
      if (!_holdFastReverse) return;
      var target = _position - backStep;
      if (target < Duration.zero) target = Duration.zero;
      await _seekBoth(target);
    });
  }

  void _stopHoldFastReverse() {
    if (!_holdFastReverse) return;
    _holdFastReverse = false;
    _reverseTick?.cancel();
    _reverseTick = null;
    if (_frStartedFromPause) {
      unawaited(_player.pause());
    } else {
      // 정상 체인 복귀(속도/피치 등)
      unawaited(_applyAudioChainDebounced());
    }
    _frStartedFromPause = false;
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

    if (evt.logicalKey == LogicalKeyboardKey.equal) {
      if (evt is KeyDownEvent) {
        _startHoldFastForward();
      } else if (evt is KeyUpEvent) {
        _stopHoldFastForward();
      }
      return KeyEventResult.handled;
    }

    if (evt.logicalKey == LogicalKeyboardKey.minus) {
      if (evt is KeyDownEvent) {
        _startHoldFastReverse();
      } else if (evt is KeyUpEvent) {
        _stopHoldFastReverse();
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
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          LogicalKeySet(LogicalKeyboardKey.space):
              const _PlayFromStartOrPauseIntent(),

          // 루프/마커
          LogicalKeySet(LogicalKeyboardKey.keyL): const _ToggleLoopIntent(),
          LogicalKeySet(LogicalKeyboardKey.keyE): const _SetLoopIntent(true),
          LogicalKeySet(LogicalKeyboardKey.keyD): const _SetLoopIntent(false),
          LogicalKeySet(LogicalKeyboardKey.keyM): const _AddMarkerIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit1):
              const _JumpMarkerIntent(1),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit2):
              const _JumpMarkerIntent(2),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit3):
              const _JumpMarkerIntent(3),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit4):
              const _JumpMarkerIntent(4),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit5):
              const _JumpMarkerIntent(5),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit6):
              const _JumpMarkerIntent(6),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit7):
              const _JumpMarkerIntent(7),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit8):
              const _JumpMarkerIntent(8),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit9):
              const _JumpMarkerIntent(9),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowLeft):
              const _PrevNextMarkerIntent(false),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowRight):
              const _PrevNextMarkerIntent(true),

          // 피치(키 조정)
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowUp):
              const _PitchUpIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown):
              const _PitchDownIntent(),

          // 템포 프리셋
          LogicalKeySet(LogicalKeyboardKey.digit5): const _SpeedPresetIntent(
            0.5,
          ),
          LogicalKeySet(LogicalKeyboardKey.digit6): const _SpeedPresetIntent(
            0.6,
          ),
          LogicalKeySet(LogicalKeyboardKey.digit7): const _SpeedPresetIntent(
            0.7,
          ),
          LogicalKeySet(LogicalKeyboardKey.digit8): const _SpeedPresetIntent(
            0.8,
          ),
          LogicalKeySet(LogicalKeyboardKey.digit9): const _SpeedPresetIntent(
            0.9,
          ),
          LogicalKeySet(LogicalKeyboardKey.digit0): const _SpeedPresetIntent(
            1.0,
          ),

          // 템포 -5% / +5% : [ / ]
          LogicalKeySet(LogicalKeyboardKey.bracketLeft):
              const _TempoNudgeIntent(-5),
          LogicalKeySet(LogicalKeyboardKey.bracketRight):
              const _TempoNudgeIntent(5),

          // === ZOOM ===
          const SingleActivator(LogicalKeyboardKey.equal, alt: true):
              _ZoomIntent(true), // Alt+=
          const SingleActivator(LogicalKeyboardKey.minus, alt: true):
              _ZoomIntent(false), // Alt+-
          const SingleActivator(LogicalKeyboardKey.digit0, alt: true):
              _ZoomResetIntent(), // Alt+0
          const SingleActivator(LogicalKeyboardKey.comma, alt: true):
              _ZoomIntent(false), // Alt+,
          const SingleActivator(LogicalKeyboardKey.period, alt: true):
              _ZoomIntent(true), // Alt+.
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _PlayFromStartOrPauseIntent:
                CallbackAction<_PlayFromStartOrPauseIntent>(
                  onInvoke: (_) {
                    _spacePlayBehavior();
                    return null;
                  },
                ),
            _ToggleLoopIntent: CallbackAction<_ToggleLoopIntent>(
              onInvoke: (_) {
                setState(() {
                  _loopEnabled = !_loopEnabled;
                  _loopRemaining = -1;
                  if (_loopEnabled) {
                    _syncStartCueToAIfPossible();
                  }
                });
                _wf.setLoop(on: _loopEnabled);
                _debouncedSave();
                return null;
              },
            ),
            _SetLoopIntent: CallbackAction<_SetLoopIntent>(
              onInvoke: (i) {
                _setLoopPoint(isA: i.isA);
                return null;
              },
            ),
            _AddMarkerIntent: CallbackAction<_AddMarkerIntent>(
              onInvoke: (_) {
                _addMarker();
                return null;
              },
            ),
            _ZoomIntent: CallbackAction<_ZoomIntent>(
              onInvoke: (i) {
                _zoom(i.zoomIn ? 1.25 : 0.8);
                return null;
              },
            ),
            _JumpMarkerIntent: CallbackAction<_JumpMarkerIntent>(
              onInvoke: (i) {
                _jumpToMarkerIndex(i.i1based);
                return null;
              },
            ),
            _PrevNextMarkerIntent: CallbackAction<_PrevNextMarkerIntent>(
              onInvoke: (i) {
                _jumpPrevNextMarker(next: i.next);
                return null;
              },
            ),
            _PitchUpIntent: CallbackAction<_PitchUpIntent>(
              onInvoke: (_) {
                _pitchDelta(1);
                return null;
              },
            ),
            _PitchDownIntent: CallbackAction<_PitchDownIntent>(
              onInvoke: (_) {
                _pitchDelta(-1);
                return null;
              },
            ),
            _SpeedPresetIntent: CallbackAction<_SpeedPresetIntent>(
              onInvoke: (i) {
                _setSpeed(i.value);
                return null;
              },
            ),
            _TempoNudgeIntent: CallbackAction<_TempoNudgeIntent>(
              onInvoke: (i) {
                _nudgeSpeed(i.deltaPercent);
                return null;
              },
            ),
            _VolumeIntent: CallbackAction<_VolumeIntent>(
              onInvoke: (i) {
                _nudgeVolume(i.delta);
                return null;
              },
            ),
            _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
              onInvoke: (_) {
                _zoomReset();
                return null;
              },
            ),
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            canRequestFocus: true,
            skipTraversal: true,
            onKeyEvent: _onKeyEvent,
            child: Scaffold(
              appBar: AppBar(
                title: Text('스마트 미디어 플레이어 — $title'),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      child: SaveStatusIndicator(
                        status: _saveStatus,
                        lastSavedAt: _lastSavedAt,
                        pendingRetryCount: _pendingRetryCount,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '단축키 안내',
                    onPressed: _showHotkeys,
                    icon: const Icon(Icons.help_outline),
                  ),
                ],
              ),
              body: LayoutBuilder(
                builder: (ctx, c) {
                  final double viewportW = c.maxWidth;
                  final double viewportH = c.maxHeight;
                  final double videoMaxHeight = _isVideo
                      ? viewportW * 9 / 16
                      : 0.0;

                  return Stack(
                    children: [
                      // === 본문 (아래 레이어) ===
                      SingleChildScrollView(
                        controller: _scrollCtl,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: c.maxHeight - 40,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_isVideo && _videoCtrl != null) ...[
                                SizedBox(
                                  height: videoMaxHeight,
                                  width: viewportW,
                                ),
                                const SizedBox(height: 12),
                              ],

                              // ✅ 파형
                              AppSection(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  8,
                                  10,
                                  8,
                                ),
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: WaveformPanel(
                                    controller: _wf,
                                    mediaPath: widget.mediaPath,
                                    mediaHash: widget.mediaHash,
                                    cacheDir: _cacheDir,
                                    onStateDirty: () => _debouncedSave(),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 5),
                              _buildTopTransportBar(),
                              const SizedBox(height: 5),

                              // === 템포 / 키 / 볼륨 ===
                              _buildControlRow(),

                              const SizedBox(height: 5),

                              // ===== Markers =====
                              AppSection(
                                child: Row(
                                  children: [
                                    AppMiniButton(
                                      icon: Icons.add,
                                      label: '마커 추가 (M)',
                                      onPressed: _addMarker,
                                      compact: true,
                                      iconSize: 18,
                                      fontSize: 12,
                                      minSize: const Size(34, 30),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: [
                                            for (
                                              int i = 0;
                                              i < _markers.length;
                                              i++
                                            )
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 4,
                                                ),
                                                child: _MarkerChip(
                                                  label: _markers[i].label,
                                                  color: _markers[i].color,
                                                  onJump: () =>
                                                      _jumpToMarkerIndex(i + 1),
                                                  onEdit: () => _editMarker(i),
                                                  onDelete: () =>
                                                      _deleteMarker(i),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 6),
                              Builder(
                                builder: (context) {
                                  final hint = Theme.of(context).hintColor;
                                  return Row(
                                    children: [
                                      Icon(
                                        Icons.keyboard,
                                        size: 16,
                                        color: hint,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '마커 점프: Alt+1..9   •   이전/다음: Alt+← / Alt+→',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: hint),
                                      ),
                                    ],
                                  );
                                },
                              ),

                              const SizedBox(height: 12),

                              // 오늘 수업 메모
                              Text(
                                '오늘 수업 메모',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _notesCtl,
                                maxLines: 6,
                                onChanged: (v) {
                                  if (_notesInitApplying) return;
                                  _notes = v;
                                  _debouncedSave(saveToDb: true);
                                  LessonMemoSync.instance.pushLocal(v);
                                },
                                decoration: const InputDecoration(
                                  hintText: '오늘 배운 것/과제/포인트를 적어두세요…',
                                  border: OutlineInputBorder(),
                                ),
                              ),

                              const SizedBox(height: 8),
                              FutureBuilder<String>(
                                future: _resolveLocalSidecarPath(),
                                builder: (ctx, snap) {
                                  final scName = snap.hasData
                                      ? p.basename(snap.data!)
                                      : 'current.gtxsc';
                                  return Text(
                                    '사이드카: $scName  •  폴더: ${widget.studentDir}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // === 비디오 오버레이 (위 레이어) ===
                      if (_isVideo && _videoCtrl != null)
                        StickyVideoOverlay(
                          controller: _videoCtrl!,
                          scrollController: _scrollCtl,
                          viewportSize: Size(viewportW, viewportH),
                          collapseScrollPx: 480.0,
                          miniWidth: 360.0,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _normalizeLoopOrder() {
    if (_loopA != null &&
        _loopB != null &&
        !_loopA!.isNegative &&
        !_loopB!.isNegative) {
      if (_duration == Duration.zero) return;
      if (_loopA! >= _loopB!) {
        final two = const Duration(seconds: 2);
        final newB = ((_loopA! + two) < _duration)
            ? _loopA! + two
            : (_duration - const Duration(milliseconds: 1));
        setState(() => _loopB = newB);
      }
    }
  }
 
  String _fmtLoopRepeat(int v) => v == 0 ? '∞' : '$v';

  Future<void> _promptLoopRepeatInput() async {
    final ctl = TextEditingController(text: _loopRepeat.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('반복횟수 입력 (0=∞)'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '0~200'),
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
      await _setLoopRepeatExact(n); // ✅ 저장 & 잔여 즉시 반영
    }
  }


  void _resetRemainingAfterRepeatChange() {
    // 루프가 켜져 있고 반복이 유한(>0)이라면 '잔여'를 즉시 해당 값으로 리셋
    setState(() {
      _loopRemaining = (_loopEnabled && _loopRepeat > 0) ? _loopRepeat : -1;
    });
  }

  void _changeLoopRepeat(int delta) {
    final next = (_loopRepeat + delta).clamp(0, 200);
    setState(() => _loopRepeat = next);
    _wf.loopRepeat.value = _loopRepeat;
    _debouncedSave();
    _resetRemainingAfterRepeatChange();
  }

  Future<void> _setLoopRepeatExact(int v) async {
    setState(() => _loopRepeat = v.clamp(0, 200));
    _wf.loopRepeat.value = _loopRepeat;
    _debouncedSave();
    _resetRemainingAfterRepeatChange();
  }

// 현장 최적화 4종 (1/2/4/8마디)
  static const List<_LoopPreset> _loopPresets = [
    _LoopPreset('1마디 · 50회', 50),
    _LoopPreset('2마디 · 30회', 30),
    _LoopPreset('4마디 · 20회', 20),
    _LoopPreset('8마디 · 12회', 12),
  ];


  Future<void> _spacePlayBehavior() async {
    final dynamic plat = _player.platform;
    try {
      final st = _player.state;
      debugPrint(
        '[SMP] before play: pos=${st.position}, playing=${st.playing}',
      );
      debugPrint("[SMP] mpv.pause(before)=${await plat?.getProperty('pause')}");
      debugPrint("[SMP] mpv.af(before)=${await plat?.getProperty('af')}");
    } catch (_) {}

    final playing = _player.state.playing;
    if (playing) {
      await _player.pause();
    } else {
      final d = _clamp(_startCue, Duration.zero, _duration);
      await _seekBoth(d);

      // ✅ 재생 전 즉시 체인 적용
      await _applyAudioChain();

      await _player.play();

      // ✅ 300ms 후 보정 적용 + 로그
      Future.delayed(const Duration(milliseconds: 300), () async {
        await _applyAudioChainDebounced();
        await _logAf(' +300ms');
      });
    }
  }


  void _syncStartCueToAIfPossible() {
    if (_loopA != null) {
      setState(() {
        _startCue = _clamp(_loopA!, Duration.zero, _duration);
      });
    }
  }

  void _setLoopPoint({required bool isA}) {
    final t = _position;

    if (isA) {
      // ====== E: A를 현재 위치로 설정 + B 초기화 + 루프 OFF (자동재생 없음) ======
      setState(() {
        _loopA = t;
        _loopB = null;
        _loopEnabled = false;
        _loopRemaining = -1;
        _startCue = _clamp(t, Duration.zero, _duration);
      });

      _wf.selectionA.value = _loopA;
      _wf.selectionB.value = null;
      _wf.setLoop(a: _loopA, b: null, on: false);
      _wf.loopOn.value = false;
      _wf.setStartCue(_startCue);

      _debouncedSave();
      return;
    }

    // ====== D: “현재 시작점(_startCue)”을 A로, B는 현재 위치로 설정 (자동재생 없음) ======
    final baseA = _clamp(_startCue, Duration.zero, _duration);
    setState(() {
      _loopA = baseA;
      _loopB = t;
      _normalizeLoopOrder();
      _loopRemaining = -1;
    });

    _wf.selectionA.value = _loopA;
    _wf.selectionB.value = _loopB;

    final ready = _loopA != null && _loopB != null && _loopA! < _loopB!;
    _wf.setLoop(a: _loopA, b: _loopB, on: ready || _loopEnabled);

    if (ready) {
      setState(() => _loopEnabled = true);
      _wf.loopOn.value = true;
      // ⛔️ 자동 재생 제거
      _debouncedSave();
    } else {
      _debouncedSave();
    }
  }

  void _zoom(double factor) {
    const double maxWidth = 1.0;
    final double durMs = _duration.inMilliseconds.toDouble();
    final double startFrac = (durMs <= 0)
        ? 0.0
        : (_startCue.inMilliseconds / durMs).clamp(0.0, 1.0);

    final double newWidth = (_viewWidth / factor).clamp(
      SmartMediaPlayerScreen._minViewWidth,
      maxWidth,
    );

    final double newStart = startFrac.clamp(
      0.0,
      (1.0 - newWidth).clamp(0.0, 1.0),
    );

    setState(() {
      _viewWidth = newWidth;
      _viewStart = newStart;
    });
    _wf.setViewport(start: _viewStart, width: _viewWidth);
  }

  void _zoomReset() {
    setState(() {
      _viewWidth = 1.0;
      _viewStart = 0.0;
    });
    _wf.setViewport(start: _viewStart, width: _viewWidth);
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = double.parse(v.clamp(0.5, 1.5).toStringAsFixed(2)));
    await _applyAudioChainDebounced();
    _debouncedSave();
  }

  Future<void> _nudgeSpeed(int deltaPercent) async {
    final step = deltaPercent / 100.0;
    await _setSpeed(_speed + step);
  }

  Future<void> _pitchDelta(int d) async {
    setState(() {
      _pitchSemi = (_pitchSemi + d).clamp(-7, 7);
    });
    await _applyAudioChainDebounced();
    _debouncedSave();
  }

  Future<void> _setPitch(int semis) async {
    setState(() {
      _pitchSemi = semis.clamp(-7, 7);
    });
    await _applyAudioChainDebounced();
    _debouncedSave();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _setVolume(int v) async {
    setState(() => _volume = v.clamp(0, 150));
    await _applyAudioChainDebounced();
    _debouncedSave();
  }

  Future<void> _nudgeVolume(int delta) async {
    await _setVolume(_volume + delta);
  }

  void _addMarker() {
    final idx = _markers.length + 1;
    final label = _lettersForIndex(idx);
    setState(() => _markers.add(MarkerPoint(_position, label)));
    _wf.setMarkers(_markers.map((m) => WfMarker(m.t, m.label)).toList());
    _debouncedSave();
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
      _debouncedSave();
    }
  }

  Future<void> _jumpToMarkerIndex(int i1based) async {
    final i = i1based - 1;
    if (i < 0 || i >= _markers.length) return;
    final d = _markers[i].t;
    const pad = Duration(milliseconds: 5);
    final dur = _duration;
    final target = _clamp(d + pad, Duration.zero, dur);
    setState(() {
      _loopRemaining = -1;
      _startCue = target;
    });
    await _seekBoth(target);
  }

  Future<void> _jumpPrevNextMarker({required bool next}) async {
    if (_markers.isEmpty || _duration == Duration.zero) return;
    final nowMs = _position.inMilliseconds;
    final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));
    const pad = Duration(milliseconds: 5);
    if (next) {
      for (final m in sorted) {
        if (m.t.inMilliseconds > nowMs + 10) {
          final tgt = m.t + pad;
          setState(() {
            _loopRemaining = -1;
            _startCue = tgt;
          });
          await _seekBoth(tgt);
          return;
        }
      }
      final tgt = sorted.last.t + pad;
      setState(() {
        _loopRemaining = -1;
        _startCue = tgt;
      });
      await _seekBoth(tgt);
    } else {
      for (var i = sorted.length - 1; i >= 0; i--) {
        if (sorted[i].t.inMilliseconds < nowMs - 10) {
          final tgt = sorted[i].t + pad;
          setState(() {
            _loopRemaining = -1;
            _startCue = tgt;
          });
          await _seekBoth(tgt);
          return;
        }
      }
      final tgt = sorted.first.t + pad;
      setState(() {
        _loopRemaining = -1;
        _startCue = tgt;
      });
      await _seekBoth(tgt);
    }
  }

  void _deleteMarker(int index) {
    if (index < 0 || index >= _markers.length) return;
    setState(() => _markers.removeAt(index));
    _wf.setMarkers(
      _markers
          .map((e) => WfMarker.named(time: e.t, label: e.label, color: e.color))
          .toList(),
    );
    _debouncedSave();
  }
}

// ---- Intents ----
class _PlayFromStartOrPauseIntent extends Intent {
  const _PlayFromStartOrPauseIntent();
}

class _ToggleLoopIntent extends Intent {
  const _ToggleLoopIntent();
}

class _SetLoopIntent extends Intent {
  final bool isA;
  const _SetLoopIntent(this.isA);
}

class _AddMarkerIntent extends Intent {
  const _AddMarkerIntent();
}

class _ZoomIntent extends Intent {
  final bool zoomIn;
  const _ZoomIntent(this.zoomIn);
}

class _JumpMarkerIntent extends Intent {
  final int i1based;
  const _JumpMarkerIntent(this.i1based);
}

class _PrevNextMarkerIntent extends Intent {
  final bool next;
  const _PrevNextMarkerIntent(this.next);
}

class _PitchUpIntent extends Intent {
  const _PitchUpIntent();
}

class _PitchDownIntent extends Intent {
  const _PitchDownIntent();
}

class _SpeedPresetIntent extends Intent {
  final double value;
  const _SpeedPresetIntent(this.value);
}

class _VolumeIntent extends Intent {
  final int delta;
  const _VolumeIntent(this.delta);
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}

// 교체: _HoldIconButton
class _HoldIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onDown;
  final VoidCallback onUp;
  const _HoldIconButton({
    required this.icon,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onDown(),
      onPointerUp: (_) => onUp(),
      onPointerCancel: (_) => onUp(),
      child: IconButton(
        onPressed: () {}, // 클릭은 의미 없음(홀드 전용)
        icon: Icon(icon),
        padding: EdgeInsets.zero, // ✅ 여백 제거
        constraints: const BoxConstraints.tightFor(width: 36, height: 32),
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        splashRadius: 18,
      ),
    );
  }
}

// 새 Intent: 템포 증감 (브래킷 키)
class _TempoNudgeIntent extends Intent {
  final int deltaPercent;
  const _TempoNudgeIntent(this.deltaPercent);
}

class _MarkerChip extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback onJump;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MarkerChip({
    required this.label,
    required this.onJump,
    required this.onEdit,
    required this.onDelete,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final bg = theme.colorScheme.surface;
    final fg = theme.colorScheme.onSurface;

    return Material(
      color: bg,
      shape: StadiumBorder(side: BorderSide(color: borderColor)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 26),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              const SizedBox(width: 6),
              CircleAvatar(radius: 8, backgroundColor: color!),
              const SizedBox(width: 4),
            ],
            Tooltip(
              message: '이 마커로 이동',
              child: InkWell(
                onTap: onJump,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 3,
                  ),
                  child: Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 12, color: fg),
                  ),
                ),
              ),
            ),
            Tooltip(
              message: '마커 이름 편집',
              child: InkResponse(
                onTap: onEdit,
                radius: 18,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                  child: Icon(Icons.edit, size: 18),
                ),
              ),
            ),
            Tooltip(
              message: '마커 삭제',
              child: InkResponse(
                onTap: onDelete,
                radius: 18,
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(2, 2, 6, 2),
                  child: Icon(Icons.close, size: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemainingPill extends StatelessWidget {
  final bool loopEnabled;
  final int loopRepeat;
  final int loopRemaining;
  const _RemainingPill({
    required this.loopEnabled,
    required this.loopRepeat,
    required this.loopRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final txt = !loopEnabled
        ? '잔여: -'
        : (loopRepeat == 0
              ? '잔여: ∞'
              : '잔여: ${loopRemaining < 0 ? loopRepeat : loopRemaining}회');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Text(txt, style: theme.textTheme.bodySmall),
    );
  }
}

// 프리셋(라벨, 반복횟수)
class _LoopPreset {
  final String label;
  final int repeats;
  const _LoopPreset(this.label, this.repeats);
}
