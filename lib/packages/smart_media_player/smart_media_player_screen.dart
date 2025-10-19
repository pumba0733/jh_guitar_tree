// v3.07.1 | Storage sync + Lessons Realtime 양방향 메모 + XSC 완전 제거
// - Fix: Supabase Realtime filter type (use null & filter in callback)
// - Fix: duplicate _onKeyEvent removed
// - Fix: remove unused _prevRateForHold
// - Fix: MaterialStateProperty -> WidgetStateProperty
// - Fix: rename local _viewSliderUsable -> viewSliderUsable
//
// - [SIDEcar] 편집 데이터(JSON) Storage(player_sidecars) 업/다운 + 백업
// - [NOTES] lessons.memo 단일원본: SMP↔TodayLesson 실시간 동기화(Realtime)
// - [OPEN] 원격 current.json vs 로컬 파일 LWW 선택 후 적용
// - [KEEP] UI/오디오체인/루프/마커/2x홀드 등 v3.06.0 유지
//
// 필요 의존: supabase_flutter, player_sidecar_storage_service.dart, lesson_service.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../ui/components/save_status_indicator.dart';

import '../../services/lesson_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart'; // [SYNC]
import '../../services/xsc_sync_service.dart';

// ===== media_kit =====
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// NEW
import 'waveform/system/waveform_system.dart';
import 'waveform/system/waveform_panel.dart';

import 'models/marker_point.dart';
import 'sync/sidecar_sync.dart';
import 'sync/lesson_memo_sync.dart';
import 'audio/rubberband_mpv_engine.dart';
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

// ⛳️ 기존 SaveState enum 제거하고 SaveStatusIndicator의 SaveStatus 사용
class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen> {
  late final DebouncedSaver _saver;
  // media_kit
  late final Player _player;
  VideoController? _videoCtrl;
  bool _isVideo = false;

  // 구독
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _notesBusSub;

  // [SYNC] lessons.memo Realtime
  RealtimeChannel? _lessonChan;
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
  bool _muted = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;
  int _loopRepeat = 0; // 0=∞
  int _loopRemaining = -1;
  late final TextEditingController _loopRepeatCtl;

  void _onScrollTick() {
    if (!mounted) return;
    setState(() {}); // 스크롤 오프셋 변화에 맞춰 오버레이 재계산
  }
  
  // 시작점
  Duration _startCue = Duration.zero;

  // 마커
  final List<MarkerPoint> _markers = [];

  // 메모
  String _notes = '';
  late final TextEditingController _notesCtl;
  bool _notesInitApplying = true;

  // 자동 저장
  Timer? _saveDebounce;

  // ✅ 저장 상태(공용 UI 연동)
  SaveStatus _saveStatus = SaveStatus.idle;
  DateTime? _lastSavedAt;
  int _pendingRetryCount = 0;

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
    return SidecarSync.instance.resolveLocalPath(
      widget.studentDir,
      initial: widget.initialSidecar,
    );
  }


  String get _cacheDir {
    final wsRoot = Directory(widget.studentDir).parent.parent.path;
    return p.join(wsRoot, '.cache');
  }

  @override
  void initState() {
    super.initState();
    _saver = DebouncedSaver(delay: const Duration(milliseconds: 800));
    MediaKit.ensureInitialized();

    _loopRepeatCtl = TextEditingController(text: _loopRepeat.toString());
    _notesCtl = TextEditingController(text: _notes);
    _scrollCtl.addListener(_onScrollTick);

    _detectIsVideo();
    _player = Player();
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
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled, repeat: _loopRepeat);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(
      _markers.map((m) => WfMarker(m.t, m.label, color: m.color)).toList(),
    );

    // 컨트롤러 콜백 → 저장 디바운스 연결
    _wf.onViewportChanged = (s, w) {
      setState(() {
        _viewStart = s;
        _viewWidth = w;
      });
      _debouncedSave();
    };
    _wf.onLoopChanged = (a, b, on) {
      setState(() {
        _loopA = a;
        _loopB = b;
        _loopEnabled = on;
        _loopRemaining = -1;
        if (_loopEnabled) _syncStartCueToAIfPossible();
      });
      _debouncedSave();
    };
    _wf.onStartCueChanged = (d) {
      setState(() => _startCue = d);
      _debouncedSave();
    };
    _wf.onMarkersChanged = (list) {
      setState(() {
        _markers
          ..clear()
          ..addAll(list.map((e) => MarkerPoint(e.t, e.label, color: e.color)));
      });
      _debouncedSave();
    };
    _wf.onSeek = (d) async {
      setState(() {
        _loopEnabled = false;
        _loopRemaining = -1;
        _startCue = _clamp(d, Duration.zero, _duration);
      });
      await _seekBoth(d);
      _debouncedSave();
    };
    _saver.addListener(() {
      if (!mounted) return;
      setState(() {
        _saveStatus = _saver.status;
        _lastSavedAt = _saver.lastSavedAt;
        _pendingRetryCount = _saver.pendingRetryCount;
      });
    });

  }

  Future<void> _initAsync() async {
    await _openMedia();

    // ⬇️ duration 스트림 구독은 여기서 안전하게
    _durSub = _player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
      _normalizeLoopOrder();
      _wf.updateFromPlayer(pos: _position, dur: d);
    });
  }


  // =========================
  // [SYNC] 초기 동기화 시퀀스
  // =========================
  Future<void> _initNotesAndSidecarSync() async {
    _notesInitApplying = true;
    try {
      // 1) 로컬/원격 사이드카 비교 후 최신본 적용
      await _loadSidecarLatest();

      // 2) lessons.memo 초기값: DB 우선, 없으면 사이드카 notes
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

      // 3) Realtime 구독 — lessons (학생, 오늘 날짜)
      _subscribeLessonMemoRealtime();
    } finally {
      _notesInitApplying = false;
    }

    // 첫 자동 저장(로컬/스토리지 갱신), DB 저장은 미루기
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
          _saveSidecar(saveToDb: false, uploadToStorage: true);
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
      _saveSidecar(saveToDb: false, uploadToStorage: true);
      Future.delayed(
        const Duration(milliseconds: 50),
        () => _hydratingMemo = false,
      );
    });
  }


  @override
  void dispose() {
    _saveDebounce?.cancel();
    // 마지막 저장: 로컬 + 스토리지(메모 DB는 중복 저장 방지)
    unawaited(_saveSidecar(saveToDb: false, uploadToStorage: true));
    _lessonChan?.unsubscribe();
    _notesBusSub?.cancel(); // [NOTES BUS]
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _reverseTick?.cancel();
    _player.dispose();
    _loopRepeatCtl.dispose();
    _notesCtl.dispose();
    _focusNode.dispose();
    _posWatchdog?.cancel();
    _scrollCtl.removeListener(_onScrollTick);
    _scrollCtl.dispose(); // [PIP]
    LessonMemoSync.instance.dispose();
    _saver.dispose();
    super.dispose();
    
  }

  // ====== 사이드카 로드 (원격/로컬 LWW) ======
  Future<void> _loadSidecarLatest() async {
    final latest = await SidecarSync.instance.loadLatest(
      studentId: widget.studentId,
      mediaHash: widget.mediaHash,
      studentDir: widget.studentDir,
      initial: widget.initialSidecar,
    );
    if (latest.isNotEmpty) {
      _applySidecarMap(latest);
    }
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
      _loopRepeatCtl.text = _loopRepeat.toString();
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
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled, repeat: _loopRepeat);
    _wf.setStartCue(_startCue);
    _wf.setMarkers(_markers.map((e) => WfMarker(e.t, e.label, color: e.color)).toList());

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
      if (!_isVideo) {
        await plat?.setProperty('vid', 'no');
      }
      await plat?.setProperty('ao', 'coreaudio');
      await plat?.setProperty('audio-exclusive', 'no');
      await plat?.setProperty('audio-device', 'auto');
    } catch (_) {}

    await _player.open(Media(widget.mediaPath), play: false);

    _posSub = _player.stream.position.listen((pos) async {
      _wf.updateFromPlayer(pos: pos, dur: _duration);
      if (!mounted) return;
      setState(() => _position = pos);

      // 루프 처리
      if (_loopEnabled && _loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (pos < a) {
          await _seekBoth(a);
          return;
        }
        if (b > Duration.zero && pos >= b) {
          if (_loopRepeat == 0) {
            await _seekBoth(a);
            return;
          } else {
            if (_loopRemaining < 0) {
              _loopRemaining = _loopRepeat;
            } else {
              _loopRemaining -= 1;
            }
            if (_loopRemaining <= 0) {
              setState(() => _loopEnabled = false);
              await _player.pause();
              _debouncedSave();
              return;
            }
            await _seekBoth(a);
            return;
          }
        }
      }

      // 끝 처리: (루프 OFF일 때) 파일 끝에 닿아도 정지하지 않도록 여기서는 아무 것도 하지 않음.
      // 실제 되감기+재생은 _player.stream.completed 구독에서 확정적으로 처리.
      final dur = _duration;
      if (!_loopEnabled && dur > Duration.zero && pos >= dur) {
        // no-op; completed 이벤트에서 처리
        return;
      }

    });

    _playingSub = _player.stream.playing.listen((_) {
      if (!mounted) return;
      setState(() {});
    });

    _completedSub = _player.stream.completed.listen((done) async {
      if (!mounted || !done) return;

      // 루프 기능이 켜져 있으면 기존 A–B 루프 로직에 맡김
      if (_loopEnabled) return;

      final dur = _duration;
      if (dur <= Duration.zero) return;

      // 시작점으로 안전하게 점프(1ms 오프셋으로 튕김 방지) 후 즉시 재생
      final cue = _clamp(_startCue, Duration.zero, dur);
      const eps = Duration(milliseconds: 1);
      final target = (dur > eps)
          ? _clamp(cue + eps, Duration.zero, dur - eps)
          : Duration.zero;

      await _seekBoth(target);
      await _player.play();
    });

    await _applyAudioChain();
  }

  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Future<void> _applyAudioChain() async {
    await RubberbandMpvEngine.I.apply(
      player: _player,
      isVideo: _isVideo,
      muted: _muted,
      volumePercent: _volume,
      speed: _speed,
      pitchSemi: _pitchSemi,
    );
  }



  // ===== 분리된 패널 UI =====
  Widget _buildVolumePanel(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('볼륨'),
              const SizedBox(width: 8),
              Tooltip(
                message: _muted ? '음소거 해제' : '음소거',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: _toggleMute,
                  icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$_volume%'),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Tooltip(
                message: '볼륨 -5% (-)',
                child: IconButton(
                  onPressed: () => _nudgeVolume(-5),
                  icon: const Icon(Icons.remove),
                ),
              ),
              Expanded(
                child: Slider(
                  value: _volume.toDouble(),
                  min: 0,
                  max: 150,
                  divisions: 150,
                  label: '$_volume%',
                  onChanged: (v) => _setVolume(v.round()),
                ),
              ),
              Tooltip(
                message: '볼륨 +5% (+)',
                child: IconButton(
                  onPressed: () => _nudgeVolume(5),
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('키 조정'),
              Tooltip(
                message: '키 -1 (Alt+↓)',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pitchDelta(-1),
                  icon: const Icon(Icons.remove),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${_pitchSemi >= 0 ? '+' : ''}$_pitchSemi'),
              ),
              Tooltip(
                message: '키 +1 (Alt+↑)',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pitchDelta(1),
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedPanel(BuildContext context, List<double> speedPresets) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('템포'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${(_speed * 100).round()}%'),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Tooltip(
                message: '템포 -5% ([)',
                child: IconButton(
                  onPressed: () => _nudgeSpeed(-5),
                  icon: const Icon(Icons.remove),
                ),
              ),
              Expanded(
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 1.5,
                  divisions: 100,
                  label: '${(_speed * 100).round()}%',
                  onChanged: (v) => _setSpeed(v),
                ),
              ),
              Tooltip(
                message: '템포 +5% (])',
                child: IconButton(
                  onPressed: () => _nudgeSpeed(5),
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in speedPresets)
                Tooltip(
                  message: switch (v) {
                    0.5 => '프리셋 50% (키 5)',
                    0.6 => '프리셋 60% (키 6)',
                    0.7 => '프리셋 70% (키 7)',
                    0.8 => '프리셋 80% (키 8)',
                    0.9 => '프리셋 90% (키 9)',
                    1.0 => '프리셋 100% (키 0)',
                    1.1 => '프리셋 110%',
                    1.2 => '프리셋 120%',
                    _ => '프리셋',
                  },
                  child: _SpeedPresetButton(
                    value: v,
                    selected: (v - _speed).abs() < 0.011,
                    onTap: () => _setSpeed(v),
                  ),
                ),
            ],
          ),
        ],
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
              Text('  =  키를 누르고 있는 동안 2x 재생'),
              Text('  -  키를 누르고 있는 동안 2x 역재생'),
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

  // ===== 저장 =====
  Future<void> _saveSidecar({
    bool toast = false,
    bool saveToDb = true,
    bool uploadToStorage = true, // [SYNC]
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
      'version': 'v3.07.1',
      'markers': _markers.map((e) => e.toJson()).toList(),
      'notes': _notes,
      'volume': _volume,
    };

    try {
      // 🔁 (교체 포인트) 로컬 기록 + Storage 업로드를 모듈로 이관
      await SidecarSync.instance.save(
        studentId: widget.studentId,
        mediaHash: widget.mediaHash,
        studentDir: widget.studentDir,
        json: map,
        uploadToStorage: uploadToStorage,
      );

      // lessons.memo 업서트 (옵션)
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
      await _saveSidecar(saveToDb: saveToDb, uploadToStorage: true);
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
    await _player.setRate(2.0);
  }

  Future<void> _stopHoldFastForward() async {
    if (!_holdFastForward) return;
    _holdFastForward = false;
    if (_ffStartedFromPause) {
      await _player.pause();
    } else {
      await _applyAudioChain();
    }
    _ffStartedFromPause = false;
  }

  void _startHoldFastReverse() {
    if (_holdFastReverse) return;
    _holdFastReverse = true;
    _reverseTick?.cancel();

    _frStartedFromPause = !_player.state.playing;
    if (_frStartedFromPause) {
      unawaited(_player.play());
      unawaited(_player.setRate(1.0));
    }
    _reverseTick = Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!_holdFastReverse) return;
      final back = const Duration(milliseconds: 160);
      var target = _position - back;
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
    }
    _frStartedFromPause = false;
  }

  // 키 업/다운 핸들 (=-)
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) {
    // ⛔ Alt / Ctrl / Meta 눌린 상태면 (=/-) 홀드를 무시해서
    //    Shortcuts(Alt+= / Alt+-)로 이벤트가 넘어가도록 한다.
    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    final hasBlockMods =
        mods.contains(LogicalKeyboardKey.alt) ||
        mods.contains(LogicalKeyboardKey.altLeft) ||
        mods.contains(LogicalKeyboardKey.altRight) ||
        mods.contains(LogicalKeyboardKey.control) ||
        mods.contains(LogicalKeyboardKey.meta);

    if (hasBlockMods) {
      return KeyEventResult.ignored; // ← 중요: Shortcuts로 전달
    }

    // = 키 홀드 → 2x 전진
    if (evt.logicalKey == LogicalKeyboardKey.equal) {
      if (evt is KeyDownEvent) {
        _startHoldFastForward();
      } else if (evt is KeyUpEvent) {
        _stopHoldFastForward();
      }
      return KeyEventResult.handled;
    }

    // - 키 홀드 → 2x 역재생
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
    const speedPresets = <double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2];

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

          // === ZOOM: Alt 기반(플랫폼 공통) — SingleActivator로 좌/우 Alt 모두 인식 ===
          const SingleActivator(LogicalKeyboardKey.equal, alt: true):
              _ZoomIntent(true), // Alt+=
          const SingleActivator(LogicalKeyboardKey.minus, alt: true):
              _ZoomIntent(false), // Alt+-
          const SingleActivator(LogicalKeyboardKey.digit0, alt: true):
              _ZoomResetIntent(), // Alt+0
          // (보조)
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
            onKeyEvent: _onKeyEvent, // = / - 홀드 처리
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
                  // [PIP] 전체를 Stack으로 감싸서 영상 오버레이 + 스크롤 본문 분리
                  final double viewportW = c.maxWidth;
                  final double viewportH = c.maxHeight;
                  final double videoMaxHeight = _isVideo
                      ? viewportW * 9 / 16
                      : 0.0; // 플레이스홀더 높이 (비디오일 때만)

                  return Stack(
                    children: [
                      // === 본문 (아래 레이어) ===
                      SingleChildScrollView(
                        controller: _scrollCtl, // [PIP]
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: c.maxHeight - 40,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // [PIP] 비디오가 오버레이로 올라가므로 자리만 확보
                              if (_isVideo && _videoCtrl != null) ...[
                                SizedBox(height: videoMaxHeight, width: viewportW),
                                const SizedBox(height: 12),
                              ],


                              // 중앙 타임바 + 2x 버튼들
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message: '2배속 역재생 ( - 키 )',
                                      child: _HoldIconButton(
                                        icon: Icons.fast_rewind,
                                        onDown: _startHoldFastReverse,
                                        onUp: _stopHoldFastReverse,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      '${_fmt(_position)} / ${_fmt(_duration)}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(width: 12),
                                    Tooltip(
                                      message: '2배속 재생 ( = 키 )',
                                      child: _HoldIconButton(
                                        icon: Icons.fast_forward,
                                        onDown: _startHoldFastForward,
                                        onUp: _stopHoldFastForward,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 6),

                              Slider(
                                value: _position.inMilliseconds
                                    .clamp(0, _duration.inMilliseconds)
                                    .toDouble(),
                                min: 0,
                                max:
                                    ((_duration.inMilliseconds > 0)
                                            ? _duration.inMilliseconds
                                            : 1)
                                        .toDouble(),
                                onChanged: (v) async {
                                  final d = Duration(milliseconds: v.toInt());
                                  await _wf.onSeek?.call(
                                    d,
                                  ); // 내부에서 _seekBoth + save와 동일 동작
                                },
                              ),

                              const SizedBox(height: 8),

                              // Transport — 중앙정렬
                              Center(
                                child: Wrap(
                                  runSpacing: 8,
                                  spacing: 8,
                                  alignment: WrapAlignment.center,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Tooltip(
                                      message: '시작점에서 재생/일시정지 (Space)',
                                      child: FilledButton.icon(
                                        onPressed: _spacePlayBehavior,
                                        icon: Icon(
                                          _player.state.playing
                                              ? Icons.pause
                                              : Icons.play_arrow,
                                        ),
                                        label: const Text('시작점 재생/정지 (Space)'),
                                      ),
                                    ),
                                    Tooltip(
                                      message: '현재 위치를 시작점으로 지정',
                                      child: OutlinedButton(
                                        onPressed: () {
                                          setState(() {
                                            _startCue = _clamp(
                                              _position,
                                              Duration.zero,
                                              _duration,
                                            );
                                          });
                                          _debouncedSave();
                                          _wf.setStartCue(_startCue);
                                        },
                                        child: const Text('시작점=현재'),
                                      ),
                                    ),
                                    Tooltip(
                                      message: 'A 지점(단축키 E)을 시작점으로 지정',
                                      child: OutlinedButton(
                                        onPressed: () {
                                          if (_loopA != null) {
                                            setState(() {
                                              _startCue = _clamp(
                                                _loopA!,
                                                Duration.zero,
                                                _duration,
                                              );
                                            });
                                            _debouncedSave();
                                          }
                                          _wf.setStartCue(_startCue);
                                        },
                                        child: const Text('시작점=A'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 8),

                              // ===== 볼륨 / 템포 =====
                              LayoutBuilder(
                                builder: (ctx, box) {
                                  final wide = box.maxWidth >= 900;
                                  final children = [
                                    Expanded(child: _buildVolumePanel(context)),
                                    const SizedBox(width: 16, height: 16),
                                    Expanded(
                                      child: _buildSpeedPanel(
                                        context,
                                        speedPresets,
                                      ),
                                    ),
                                  ];
                                  return wide
                                      ? Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: children,
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: children,
                                        );
                                },
                              ),

                              const Divider(height: 24),

                              // Waveform
                              WaveformPanel(
                                controller: _wf,
                                mediaPath: widget.mediaPath,
                                mediaHash: widget.mediaHash,
                                cacheDir: _cacheDir,
                                onStateDirty: () => _debouncedSave(),
                              ),

                              if (_duration > Duration.zero) ...[
                                const SizedBox(height: 6),

                                // === ZOOM 슬라이더 (절대 배율: 1.0x ~ SmartMediaPlayerScreen._zoomMax) ===
                                Row(
                                  children: [
                                    const Text('줌'),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Slider(
                                        value: (1.0 / _viewWidth).clamp(
                                          1.0,
                                          SmartMediaPlayerScreen._zoomMax,
                                        ),
                                        min: 1.0,
                                        max: SmartMediaPlayerScreen._zoomMax,
                                        divisions:
                                            (SmartMediaPlayerScreen._zoomMax -
                                                    1)
                                                .toInt(),
                                        label:
                                            '${(1.0 / _viewWidth).clamp(1.0, SmartMediaPlayerScreen._zoomMax).toStringAsFixed(1)}x',
                                        onChanged: (zoom) {
                                          _setZoom(zoom);
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${(1.0 / _viewWidth).clamp(1.0, SmartMediaPlayerScreen._zoomMax).toStringAsFixed(1)}x',
                                    ),
                                    const SizedBox(width: 12),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Tooltip(
                                          message: '줌아웃 (Alt+-)',
                                          child: IconButton(
                                            onPressed: () => _zoom(0.8),
                                            icon: const Icon(Icons.zoom_out),
                                          ),
                                        ),
                                        Tooltip(
                                          message: '줌인 (Alt+=)',
                                          child: IconButton(
                                            onPressed: () => _zoom(1.25),
                                            icon: const Icon(Icons.zoom_in),
                                          ),
                                        ),
                                        Tooltip(
                                          message: '줌 리셋 (Alt+0)',
                                          child: IconButton(
                                            onPressed: _zoomReset,
                                            icon: const Icon(Icons.fullscreen),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),


                                // === 위치(팬) 슬라이더: 확대 상태에서만 노출 ===
                                if (_viewWidth < 0.999) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      const Text('위치'),
                                      Expanded(
                                        child: Slider(
                                          value: _viewStart,
                                          min: 0,
                                          max: (1 - _viewWidth).clamp(
                                            0.0,
                                            1.0 - 1e-9,
                                          ),
                                          onChanged: (v) {
                                            final maxStart = (1 - _viewWidth).clamp(0.0, 1.0);
                                            final clamped = v.clamp(0.0, maxStart).toDouble();
                                            setState(
                                              () => _viewStart = clamped,
                                            );
                                            _wf.setViewport(
                                              start: _viewStart,
                                            ); // ✅ 컨트롤러에도 반영
                                          },    
                                        ),
                                      ),
                                      // 전체 대비 현재 뷰의 좌측 경계 퍼센트(가독을 원하면 삭제 가능)
                                      Text('${(_viewStart * 100).round()}%'),
                                    ],
                                  ),
                                ],
                              ],

                              const SizedBox(height: 12),

                              // ===== A/B & Loop + 반복횟수 =====
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  // A 버튼
                                  Tooltip(
                                    message: '루프 시작으로 지정 (E)',
                                    child: OutlinedButton(
                                      onPressed: () => _setLoopPoint(isA: true),
                                      child: Text(
                                        _loopA == null
                                            ? '루프 시작 (E)'
                                            : '🔁 루프 시작 (${_fmt(_loopA!)})',
                                      ),
                                    ),
                                  ),

                                  // B 버튼
                                  Tooltip(
                                    message: '루프 끝으로 지정 (D)',
                                    child: OutlinedButton(
                                      onPressed: () =>
                                          _setLoopPoint(isA: false),
                                      child: Text(
                                        _loopB == null
                                            ? '루프 끝 (D)'
                                            : '🔁 루프 끝 (${_fmt(_loopB!)})',
                                      ),
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text('반복 모드(L)'),
                                      const SizedBox(width: 6),
                                      Switch(
                                        value: _loopEnabled,
                                        onChanged: (v) {
                                          setState(() {
                                            _loopEnabled = v;
                                            _loopRemaining = -1;
                                            if (v) _syncStartCueToAIfPossible();
                                          });
                                          _wf.setLoop(on: v);
                                          _debouncedSave();
                                        },
                                      ),
                                    ],
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text('반복 횟수'),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 56,
                                        child: TextField(
                                          controller: _loopRepeatCtl,
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly,
                                          ],
                                          onSubmitted: (v) {
                                            final parsed = int.tryParse(
                                              v.trim(),
                                            );
                                            if (parsed == null ||
                                                parsed < 0 ||
                                                parsed > 200) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    '반복 횟수는 0~200 사이의 정수여야 합니다. (0=무한)',
                                                  ),
                                                ),
                                              );
                                              return;
                                            }
                                            setState(() {
                                              _loopRepeat = parsed;
                                              _loopRepeatCtl.text = parsed
                                                  .toString();
                                              _loopRemaining = -1;
                                            });
                                            _debouncedSave();
                                          },
                                          decoration: const InputDecoration(
                                            isDense: true,
                                            contentPadding:
                                                EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                ),
                                            helperText: '0 = 무한반복',
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      if (_loopEnabled &&
                                          _loopRepeat > 0 &&
                                          _loopRemaining >= 0) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          '잔여 $_loopRemaining회',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),

                              const SizedBox(height: 12),

                              // ===== Markers =====
                              Row(
                                children: [
                                  Tooltip(
                                    message: '마커 추가 (M)',
                                    child: FilledButton.icon(
                                      onPressed: _addMarker,
                                      icon: const Icon(Icons.add),
                                      label: const Text('마커 추가 (M)'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const SizedBox(width: 12),
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
                                                right: 6,
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
                                  _debouncedSave(
                                    saveToDb: true,
                                  ); // DB 업서트 + 사이드카 디바운스
                                  XscSyncService.instance.pushNotes(
                                    v,
                                  ); // 로컬 버스 브로드캐스트
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
                                    '사이드카: $scName  •  폴더: $widget.studentDir',
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

  Future<void> _spacePlayBehavior() async {
    final dynamic plat = _player.platform;
    try {
      final st = _player.state;
      debugPrint('[SMP] before play: pos=$st.position, playing=$st.playing');
      debugPrint("[SMP] mpv.pause(before)=${await plat?.getProperty('pause')}");
      debugPrint("[SMP] mpv.af(before)=${await plat?.getProperty('af')}");
    } catch (_) {}

    final playing = _player.state.playing;
    if (playing) {
      await _player.pause();
    } else {
      final d = _clamp(_startCue, Duration.zero, _duration);
      await _seekBoth(d);

      try {
        final dynamic plat = _player.platform;
        await plat?.setProperty('mute', _muted ? 'yes' : 'no');
        await plat?.setProperty('volume', '${_volume.clamp(0, 100)}');
        await plat?.setProperty('audio-device', 'auto');
      } catch (_) {}

      _debouncedSave();
      await _player.play();
      await _applyAudioChain();

      Future.delayed(const Duration(milliseconds: 300), () async {
        try {
          final p1 = await plat?.getProperty('playback-time');
          final paused = await plat?.getProperty('pause');
          final afnow = await plat?.getProperty('af');
          debugPrint(
            '[SMP] +300ms: playback-time=$p1, pause=$paused, af(now)=$afnow',
          );
        } catch (_) {}
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
    setState(() {
      if (isA) {
        _loopA = t;
        _syncStartCueToAIfPossible();
      } else {
        _loopB = t;
      }
      _normalizeLoopOrder();
      _loopRemaining = -1;
    });
    _wf.setLoop(
      a: isA ? _loopA : null,
      b: isA ? null : _loopB,
      on: _loopEnabled,
    );
    _debouncedSave();
  }

  void _zoom(double factor) {
    const double maxWidth = 1.0; // 전체 보기
    final double centerT = (_duration.inMilliseconds == 0)
        ? 0.5
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);

    final double newWidth = (_viewWidth / factor).clamp(
      SmartMediaPlayerScreen._minViewWidth,
      maxWidth,
    );
    final double newStart = (centerT - newWidth / 2).clamp(0.0, 1.0 - newWidth);

    setState(() {
      _viewWidth = newWidth;
      _viewStart = newStart;
    });
    _wf.setViewport(start: _viewStart, width: _viewWidth);
  }

 
  // 전체 보기를 기본값으로 되돌림
  void _zoomReset() {
    setState(() {
      _viewWidth = 1.0;
      _viewStart = 0.0;
    });
    _wf.setViewport(start: _viewStart, width: _viewWidth);
  }

  // 절대 줌 배율로 세팅 (zoom = 1.0은 전체 보기, 값이 커질수록 더 확대)
  // anchorT: 0.0~1.0 앵커(기준점). null이면 현재 재생 위치(_position) 기준.
  void _setZoom(double zoom, {double? anchorT}) {
    const double maxWidth = 1.0; // 전체 보기
    final double targetWidth = (1.0 / zoom).clamp(
      SmartMediaPlayerScreen._minViewWidth,
      maxWidth,
    );

    final double t =
        anchorT ??
        ((_duration.inMilliseconds == 0)
            ? 0.5
            : (_position.inMilliseconds / _duration.inMilliseconds).clamp(
                0.0,
                1.0,
              ));

    final double newStart = (t - targetWidth / 2).clamp(0.0, 1.0 - targetWidth);

    setState(() {
      _viewWidth = targetWidth;
      _viewStart = newStart;
    });
    _wf.setViewport(start: _viewStart, width: _viewWidth);
  }




  Future<void> _setSpeed(double v) async {
    setState(() => _speed = double.parse(v.clamp(0.5, 1.5).toStringAsFixed(2)));
    await _applyAudioChain();
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
    await _applyAudioChain();
    _debouncedSave();
  }

  // ===== 볼륨 컨트롤 =====
  Future<void> _setVolume(int v) async {
    setState(() => _volume = v.clamp(0, 150));
    await _applyAudioChain();
    _debouncedSave();
  }

  Future<void> _nudgeVolume(int delta) async {
    await _setVolume(_volume + delta);
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await _applyAudioChain();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _addMarker() {
    final idx = _markers.length + 1;
    final label = _lettersForIndex(idx);
    setState(() => _markers.add(MarkerPoint(_position, label)));
    _wf.setMarkers(
      _markers.map((m) => WfMarker(m.t, m.label, color: m.color)).toList(),
    );
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
        if (newLabel.isNotEmpty) {
          m.label = newLabel;
        }
      });
      _wf.setMarkers(_markers.map((e) => WfMarker(e.t, e.label, color: e.color)).toList());
      _debouncedSave();
    }
  }

  Future<void> _jumpToMarkerIndex(int i1based) async {
    final i = i1based - 1;
    if (i < 0 || i >= _markers.length) return;
    final d = _markers[i].t;
    final pad = const Duration(milliseconds: 5);
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
    _wf.setMarkers(_markers.map((e) => WfMarker(e.t, e.label, color: e.color)).toList());
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

// ---- UI helpers ----
class _SpeedPresetButton extends StatelessWidget {
  final double value; // e.g., 0.5
  final bool selected;
  final VoidCallback onTap;
  const _SpeedPresetButton({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  ButtonStyle get _compactStyle {
    return ButtonStyle(
      visualDensity: VisualDensity.compact,
      minimumSize: WidgetStateProperty.all<Size>(const Size(74, 40)),
      padding: WidgetStateProperty.all<EdgeInsetsGeometry>(
        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = '${(value * 100).round()}%';
    final child = Text(label);
    return selected
        ? FilledButton.tonal(
            onPressed: onTap,
            style: _compactStyle,
            child: child,
          )
        : OutlinedButton(onPressed: onTap, style: _compactStyle, child: child);
  }
}

// 아이콘 버튼을 "누르고 있는 동안" 동작시키기 위한 헬퍼
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
      child: IconButton(icon: Icon(icon), onPressed: () {}),
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
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              const SizedBox(width: 8),
              CircleAvatar(radius: 8, backgroundColor: color!),
              const SizedBox(width: 6),
            ],
            Tooltip(
              message: '이 마커로 이동',
              child: InkWell(
                onTap: onJump,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(label, style: TextStyle(color: fg)),
                ),
              ),
            ),
            Tooltip(
              message: '마커 이름 편집',
              child: InkResponse(
                onTap: onEdit,
                radius: 18,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                  padding: EdgeInsets.fromLTRB(4, 4, 8, 4),
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
