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
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
// [PIP] 사이즈 보간용
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'waveform/waveform_cache.dart';
import 'widgets/waveform_view.dart';
import '../../ui/components/save_status_indicator.dart';

import '../../services/lesson_service.dart';
import '../../services/player_sidecar_storage_service.dart'; // [SYNC]
import 'package:supabase_flutter/supabase_flutter.dart'; // [SYNC]
import '../../services/xsc_sync_service.dart';

// ===== media_kit =====
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class MarkerPoint {
  Duration t;
  String label;
  String? note;
  Color? color;
  MarkerPoint(this.t, this.label, {this.note, this.color});

  Map<String, dynamic> toJson() => {
    't': t.inMilliseconds,
    'label': label,
    if (note != null) 'note': note,
    if (color != null) 'color': _colorToHex(color!),
  };

  static MarkerPoint fromJson(Map<String, dynamic> m) => MarkerPoint(
    Duration(milliseconds: (m['t'] ?? 0) as int),
    (m['label'] ?? '') as String,
    note: (m['note'] as String?),
    color: _tryParseColor(m['color'] as String?),
  );

  static Color? _tryParseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      var v = hex.toUpperCase().replaceAll('#', '');
      if (v.length == 6) v = 'FF$v';
      final n = int.parse(v, radix: 16);
      return Color(n);
    } catch (_) {
      return null;
    }
  }

  static String _colorToHex(Color c) {
    final argb = c.toARGB32();
    final r = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final g = ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final b = (argb & 0xFF).toRadixString(16).padLeft(2, '0');
    return '#${(r + g + b).toUpperCase()}';
  }
}

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

// ⛳️ 기존 SaveState enum 제거하고 SaveStatusIndicator의 SaveStatus 사용
class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen> {
  // media_kit
  late final Player _player;
  VideoController? _videoCtrl;
  bool _isVideo = false;

  // 구독
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<String>? _notesBusSub;

  // [SYNC] lessons.memo Realtime
  RealtimeChannel? _lessonChan;
  bool _hydratingMemo = false; // 외부 주입 중 플래그

  // 포커스
  final FocusNode _focusNode = FocusNode(debugLabel: 'SMPFocus');

  // [PIP] 스크롤 컨트롤러 (영상 오버레이 축소/고정)
  final ScrollController _scrollCtl = ScrollController();

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

  // 파형
  List<double> _peaks = const [];
  List<double> _peaksR = const [];
  double _waveProgress = 0;

  // 뷰포트
  double _viewStart = 0.0;
  double _viewWidth = 1.0;

  // 선택 드래그
  Duration? _selectStart;
  Duration? _selectEnd;

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
    final gtx = File(p.join(widget.studentDir, 'current.gtxsc'));
    if (await gtx.exists()) return gtx.path;
    final xsc = File(p.join(widget.studentDir, 'current.xsc'));
    if (await xsc.exists()) return xsc.path;
    // 기본은 gtxsc 경로로 씀
    return gtx.path;
  }

  String get _cacheDir {
    final wsRoot = Directory(widget.studentDir).parent.parent.path;
    return p.join(wsRoot, '.cache');
  }

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();

    _loopRepeatCtl = TextEditingController(text: _loopRepeat.toString());
    _notesCtl = TextEditingController(text: _notes);
    _scrollCtl.addListener(_onScrollTick);

    _detectIsVideo();
    _player = Player();
    if (_isVideo) _videoCtrl = VideoController(_player);

    _openMedia().then((_) {
      if (mounted) _buildWaveform();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    _initNotesAndSidecarSync(); // [SYNC]
    _subscribeLocalNotesBus(); // [NOTES BUS]
    _startPosWatchdog();
    
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
    _lessonChan?.unsubscribe();
    final supa = Supabase.instance.client;

    _lessonChan = supa
        .channel('lessons-memo-${widget.studentId}-${_todayDateStr}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'lessons',
          callback: (payload) {
            final newRow = payload.newRecord;
            if (newRow == null) return;
            final sid = (newRow['student_id'] ?? '').toString();
            final dateStr = (newRow['date'] ?? '').toString();
            final isToday = dateStr == _todayDateStr;
            if (sid == widget.studentId && isToday) {
              final memo = (newRow['memo'] ?? '').toString();
              if (memo != _notes && mounted) {
                _hydratingMemo = true;
                setState(() {
                  _notes = memo;
                  _notesCtl.text = memo;
                });
                // ✅ DB 에코 저장은 금지하고, 로컬/Storage만 즉시 동기화
                _saveSidecar(saveToDb: false, uploadToStorage: true);
                Future.delayed(
                  const Duration(milliseconds: 50),
                  () => _hydratingMemo = false,
                );
              }
            }
          },
        )
        .subscribe();
  }

  void _subscribeLocalNotesBus() {
    _notesBusSub?.cancel();
    _notesBusSub = XscSyncService.instance.notesStream.listen((text) {
      if (!mounted) return;
      if (text == _notes) return; // 중복 무시
      _hydratingMemo = true;
      setState(() {
        _notes = text;
        _notesCtl.text = text;
      });
      // DB 에코 저장은 금지, 로컬/Storage만 동기화
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
    _reverseTick?.cancel();
    _player.dispose();
    _loopRepeatCtl.dispose();
    _notesCtl.dispose();
    _focusNode.dispose();
    _posWatchdog?.cancel();
    _scrollCtl.removeListener(_onScrollTick);
    _scrollCtl.dispose(); // [PIP]
    super.dispose();
  }

  // ====== 사이드카 로드 (원격/로컬 LWW) ======
  Future<void> _loadSidecarLatest() async {
    final localPath = widget.initialSidecar ?? await _resolveLocalSidecarPath();

    Map<String, dynamic>? localJson;
    if (await File(localPath).exists()) {
      try {
        localJson =
            jsonDecode(await File(localPath).readAsString())
                as Map<String, dynamic>;
      } catch (_) {}
    }

    Map<String, dynamic>? remoteJson;
    try {
      remoteJson = await PlayerSidecarStorageService.instance.downloadCurrent(
        widget.studentId,
        widget.mediaHash,
      );
    } catch (_) {}

    final latest = PlayerSidecarStorageService.instance.pickLatest(
      localJson,
      remoteJson,
    );

    if (latest.isNotEmpty) {
      // 화면 상태에 반영
      _applySidecarMap(latest);
      // 최신본을 로컬에도 기록(캐시 일치)
      try {
        await File(localPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(latest),
          flush: true,
        );
      } catch (_) {}
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

    _durSub = _player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      setState(() => _duration = d);
      _normalizeLoopOrder();
    });

    _posSub = _player.stream.position.listen((pos) async {
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

      // 끝 처리
      final dur = _duration;
      if (!_loopEnabled && dur > Duration.zero && pos >= dur) {
        await _player.pause();
        await _seekBoth(_clamp(_startCue, Duration.zero, dur));
      }
    });

    _playingSub = _player.stream.playing.listen((_) {
      if (!mounted) return;
      setState(() {});
    });

    await _applyAudioChain();
  }

  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Future<void> _applyAudioChain() async {
    try {
      final dynamic plat = _player.platform;

      // mute/volume
      try {
        await plat?.setProperty('mute', _muted ? 'yes' : 'no');
      } catch (_) {}

      final S = _speed.clamp(0.5, 1.5);
      final pitchRatio = math.pow(2.0, _pitchSemi / 12.0).toDouble();
      final totalRate = (S * pitchRatio).clamp(0.25, 4.0);
      await _player.setRate(totalRate);

      final v = _volume.clamp(0, 150);
      final baseVol = v <= 100 ? v : 100;
      try {
        await plat?.setProperty('volume', '$baseVol');
      } catch (_) {}

      // af 재구성
      try {
        await plat?.setProperty('af', '');
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 1));

      final List<String> af = [];
      if (_pitchSemi == 0) {
        if ((S - 1.0).abs() >= 0.0001) {
          if (S <= 0.60) {
            final invS = (1.0 / S).clamp(0.5, 2.0);
            af.add(
              'lavfi=[rubberband=pitch=${invS.toStringAsFixed(6)}:formant=1:transients=smooth:phase=laminar:detector=compound:channels=linked:precision=high]',
            );
          } else {
            af.add('scaletempo2');
          }
        }
      } else {
        final invPitch = (1.0 / pitchRatio).clamp(0.5, 2.0);
        af.add('atempo=${invPitch.toStringAsFixed(6)}');
      }

      if (v > 100) {
        final ratio = v / 100.0;
        final gainDb = 20.0 * math.log(ratio) / math.ln10;
        af.add('lavfi=[volume=${gainDb.toStringAsFixed(2)}dB]');
      }

      if (af.isNotEmpty) {
        await plat?.setProperty('af', af.join(','));
        debugPrint('[mpv] af=${af.join(',')}');
      }
    } catch (e) {
      debugPrint('[SMP] _applyAudioChain error: $e');
    }
  }

  // === 파형 생성 ===
  Future<void> _buildWaveform() async {
    try {
      setState(() => _waveProgress = 0.05);

      final secs = (_duration.inMilliseconds / 1000).clamp(0.2, 60 * 60 * 3);
      final target = (secs * 512).round().clamp(2048, 100000);

      final (left, right) = await WaveformCache.instance.loadOrBuildStereo(
        mediaPath: widget.mediaPath,
        cacheDir: _cacheDir,
        cacheKey: widget.mediaHash,
        targetBars: target,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _waveProgress = p);
        },
      );

      if (!mounted) return;
      setState(() {
        _peaks = left;
        _peaksR = right;
        _waveProgress = 1.0;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파형 생성 실패: $e')));
    }
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
    final path = await _resolveLocalSidecarPath();
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
      // 로컬 기록
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(map),
        flush: true,
      );

      // [SYNC] Storage 업로드(+백업)
      if (uploadToStorage) {
        unawaited(
          PlayerSidecarStorageService.instance.uploadWithBackup(
            studentId: widget.studentId,
            mediaHash: widget.mediaHash,
            json: Map<String, dynamic>.from(map),
          ),
        );
      }

      // lessons.memo 업서트
      if (saveToDb && !_hydratingMemo) {
        unawaited(_saveLessonMemoToSupabase());
      }

      if (mounted) {
        setState(() {
          _saveStatus = SaveStatus.saved;
          _lastSavedAt = now;
          // 재시도 큐를 쓰고 있다면 여기서 _pendingRetryCount 갱신
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
      await LessonService().upsert({
        'student_id': widget.studentId,
        'date': _todayDateStr,
        'memo': _notes,
      });
    } catch (_) {}
  }

  void _debouncedSave({bool saveToDb = true}) {
    _saveDebounce?.cancel();
    final flagDb = saveToDb;
    setState(() => _saveStatus = SaveStatus.saving);
    _saveDebounce = Timer(const Duration(milliseconds: 800), () {
      _saveSidecar(saveToDb: flagDb, uploadToStorage: true);
      // 완료 시점은 _saveSidecar 내부에서 saved/failed로 세팅
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

  // [PIP] 오버레이 비디오 위젯 (스크롤에 따라 크기/위치 보간)
  Widget _buildStickyVideoOverlay({
    required double viewportWidth,
    required double viewportHeight,
  }) {
    // _buildStickyVideoOverlay(...) 내부

    if (!_isVideo || _videoCtrl == null) return const SizedBox.shrink();

    final double maxWidth = viewportWidth;
    const double miniWidth = 360.0; // ← 축소 최종 폭(320~360 권장)
    final double hMax = maxWidth * 9 / 16;
    final double hMin = miniWidth * 9 / 16;

    // 스크롤 얼마나 하면 완전 축소되는지 (작을수록 빨리 우하단으로 감)
    const double collapseScrollPx = 480.0; // 360(빠름) ~ 640(느림) 사이 취향대로

    final double raw = _scrollCtl.hasClients ? _scrollCtl.offset : 0.0;
    final double t = Curves.easeOut.transform(
      (raw / collapseScrollPx).clamp(0.0, 1.0),
    );

    // 크기 보간
    final double w = lerpDouble(maxWidth, miniWidth, t)!;
    final double h = lerpDouble(hMax, hMin, t)!;

    // 위치 보간 (상단 중앙 → 우하단 16px)
    const double rightMargin = 16.0;
    const double bottomMargin = 16.0;
    final double leftAt0 = (viewportWidth - w) / 2.0; // 중앙정렬
    const double topAt0 = 0.0;
    final double leftAt1 = viewportWidth - w - rightMargin; // 우측 여백
    final double topAt1 = viewportHeight - h - bottomMargin;

    final double left = lerpDouble(leftAt0, leftAt1, t)!;
    final double top = lerpDouble(topAt0, topAt1, t)!;

    // 둥근 모서리 고정
    const radius = 14.0;

    return Positioned(
      top: top,
      left: left,
      width: w,
      height: h,
      child: IgnorePointer(
        ignoring: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25 * (0.5 + 0.5 * t)),
                blurRadius: lerpDouble(8, 18, t) ?? 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Video(controller: _videoCtrl!),
          ),
        ),
      ),
    );

  }


  @override
  Widget build(BuildContext context) {
    final title = p.basename(widget.mediaPath);

    final markerDurations = _markers.map((e) => e.t).toList();
    final markerLabels = _markers.map((e) => e.label).toList();
    final markerColors = _markers.map((e) => e.color).toList();

    const speedPresets = <double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2];

    final bool viewSliderUsable = _viewWidth < 0.999;

    return Listener(
      onPointerDown: (_) {
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
      },
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
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
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _onKeyEvent, // = / - 홀드 처리
            child: Scaffold(
              appBar: AppBar(
                title: Text('스마트 미디어 플레이어 — $title'),
                actions: [
                  if (_waveProgress < 1.0)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Center(
                        child: Text(
                          '파형 ${(_waveProgress * 100).toStringAsFixed(0)}%',
                        ),
                      ),
                    ),
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
                                SizedBox(
                                  height: videoMaxHeight,
                                  width: viewportW,
                                ),
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
                                  await _seekBoth(d);
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
                              SizedBox(
                                height: 190,
                                child: _peaks.isEmpty
                                    ? Row(
                                        children: [
                                          const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            '파형 준비 중… ${(_waveProgress * 100).toStringAsFixed(0)}%',
                                          ),
                                        ],
                                      )
                                    : WaveformView(
                                        peaks: _peaks,
                                        peaksRight: _peaksR,
                                        peaksAreNormalized: true,
                                        duration: _duration,
                                        position: _position,
                                        loopA: _loopA,
                                        loopB: _loopB,
                                        loopOn: _loopEnabled,
                                        markers: markerDurations,
                                        markerLabels: markerLabels,
                                        markerColors: markerColors,
                                        viewStart: _viewStart,
                                        viewWidth: _viewWidth,
                                        selectionMode: true,
                                        selectionA: _selectStart,
                                        selectionB: _selectEnd,
                                        onSeek: (d) async {
                                          setState(() {
                                            _loopEnabled = false;
                                            _loopRemaining = -1;
                                            _startCue = _clamp(
                                              d,
                                              Duration.zero,
                                              _duration,
                                            );
                                          });
                                          await _seekBoth(d);
                                          _debouncedSave();
                                        },
                                        onSelectStart: (d) => setState(() {
                                          _selectStart = d;
                                          _selectEnd = null;
                                        }),
                                        onSelectUpdate: (d) =>
                                            setState(() => _selectEnd = d),
                                        onSelectEnd: (a, b) {
                                          if (a == null || b == null) return;
                                          final A = a <= b ? a : b;
                                          var B = b >= a ? b : a;
                                          setState(() {
                                            _loopA = A;
                                            _loopB =
                                                (B -
                                                const Duration(
                                                  milliseconds: 1,
                                                ));
                                            if (_loopB! <= _loopA!) {
                                              _loopB =
                                                  A +
                                                  const Duration(
                                                    milliseconds: 500,
                                                  );
                                            }
                                            _loopEnabled = true;
                                            _loopRemaining = -1;
                                            _startCue = _clamp(
                                              A,
                                              Duration.zero,
                                              _duration,
                                            );
                                            _selectStart = null;
                                            _selectEnd = null;
                                          });
                                          _debouncedSave();
                                        },
                                        markerRailHeight: 44,
                                        startCue: _startCue,
                                        onStartCueChanged: (d) {
                                          setState(() {
                                            _startCue = _clamp(
                                              d,
                                              Duration.zero,
                                              _duration,
                                            );
                                          });
                                          _debouncedSave();
                                        },
                                        onRailTapToSeek: (d) async {
                                          await _seekBoth(d);
                                        },
                                        onMarkerDragStart: (i) {},
                                        onMarkerDragUpdate: (i, d) {
                                          setState(() {
                                            _markers[i].t = _clamp(
                                              d,
                                              Duration.zero,
                                              _duration,
                                            );
                                          });
                                        },
                                        onMarkerDragEnd: (i, d) {
                                          _debouncedSave();
                                        },
                                        onLoopAChanged: (d) {
                                          setState(() {
                                            _loopA = _clamp(
                                              d,
                                              Duration.zero,
                                              _duration,
                                            );
                                            _normalizeLoopOrder();
                                            _loopRemaining = -1;
                                            if (_loopEnabled) {
                                              _syncStartCueToAIfPossible();
                                            }
                                          });
                                          _debouncedSave();
                                        },
                                        onLoopBChanged: (d) {
                                          setState(() {
                                            _loopB = _clamp(
                                              d,
                                              Duration.zero,
                                              _duration,
                                            );
                                            _normalizeLoopOrder();
                                            _loopRemaining = -1;
                                          });
                                          _debouncedSave();
                                        },
                                      ),
                              ),

                              if (_duration > Duration.zero) ...[
                                const SizedBox(height: 6),
                                // viewWidth=100%일 때 텍스트 대체
                                if (viewSliderUsable)
                                  Row(
                                    children: [
                                      const Text('뷰'),
                                      Expanded(
                                        child: Slider(
                                          value: _viewStart,
                                          min: 0,
                                          max: (1 - _viewWidth).clamp(
                                            0.0,
                                            1.0 - 1e-9,
                                          ),
                                          onChanged: (v) => setState(() {
                                            _viewStart = v.clamp(
                                              0.0,
                                              (1 - _viewWidth).clamp(0.0, 1.0),
                                            );
                                          }),
                                        ),
                                      ),
                                      Text('${(_viewWidth * 100).round()}%'),
                                    ],
                                  )
                                else
                                  Row(
                                    children: const [
                                      Text('뷰'),
                                      SizedBox(width: 12),
                                      Icon(Icons.fullscreen),
                                      SizedBox(width: 6),
                                      Text('전체'),
                                      Spacer(),
                                      // 퍼센트 표시는 동일
                                    ],
                                  ),
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
                                  const SizedBox(width: 8),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(width: 12),
                                      Tooltip(
                                        message: '줌아웃',
                                        child: IconButton(
                                          onPressed: () => _zoom(0.8),
                                          icon: const Icon(Icons.zoom_out),
                                        ),
                                      ),
                                      Tooltip(
                                        message: '줌인',
                                        child: IconButton(
                                          onPressed: () => _zoom(1.25),
                                          icon: const Icon(Icons.zoom_in),
                                        ),
                                      ),
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
                        _buildStickyVideoOverlay(
                          viewportWidth: viewportW,
                          viewportHeight: viewportH,
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
    _debouncedSave();
  }

  void _zoom(double factor) {
    const minWidth = 0.02;
    const maxWidth = 1.0;
    final centerT = (_duration.inMilliseconds == 0)
        ? 0.5
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    var newWidth = (_viewWidth / factor).clamp(minWidth, maxWidth);
    var newStart = (centerT - newWidth / 2).clamp(0.0, 1.0 - newWidth);
    setState(() {
      _viewWidth = newWidth;
      _viewStart = newStart;
    });
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
