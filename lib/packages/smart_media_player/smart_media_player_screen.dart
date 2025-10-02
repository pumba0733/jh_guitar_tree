// lib/packages/smart_media_player/ui/smart_media_player_screen.dart
// v1.87.0 | Markers + QuickLoop + Waveform Zoom
//
// - NEW: 북마크(마커) 추가/목록/점프/삭제 (M, Alt+1..9)
// - NEW: 퀵루프 Z(±2s)/X(±5s)/C(±10s)
// - NEW: 파형 줌/스크롤 (= 줌인, - 줌아웃, 미니맵 슬라이더)
// - NEW: 루프 엣지 미세이동 Shift+, / Shift+. (±100ms)
// - KEEP: v1.86 오디오/사이드카/핫키/파형 캐시
//
// 사이드카 저장 포맷 markers: [{ "t": <ms>, "label": "M1" }]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'waveform/waveform_cache.dart';
import 'widgets/waveform_view.dart';

class MarkerPoint {
  final Duration t;
  final String label;
  MarkerPoint(this.t, this.label);

  Map<String, dynamic> toJson() => {'t': t.inMilliseconds, 'label': label};
  static MarkerPoint fromJson(Map<String, dynamic> m) => MarkerPoint(
    Duration(milliseconds: (m['t'] ?? 0) as int),
    (m['label'] ?? '') as String,
  );
}

class SmartMediaPlayerScreen extends StatefulWidget {
  final String studentId;
  final String mediaHash;
  final String mediaPath; // 로컬 재생 파일 (학생 폴더 안)
  final String studentDir; // 학생 폴더 (사이드카 저장 위치)
  final String? initialSidecar; // 있으면 로딩

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

class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;

  // UI 상태
  double _speed = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;

  // 마커
  final List<MarkerPoint> _markers = [];

  // 자동 저장 디바운스
  Timer? _saveDebounce;

  // 파형 데이터(0..1)
  List<double> _peaks = const [];
  double _waveProgress = 0; // 0..1

  // 파형 뷰포트(줌/스크롤): 0..1
  double _viewStart = 0.0;
  double _viewWidth = 1.0; // 1.0=전체, 0.1=10%만 보기

  // 사이드카 경로
  String get _sidecarPath => p.join(widget.studentDir, 'current.gtxsc');

  // 캐시 디렉토리 (WORKSPACE/.cache)
  String get _cacheDir {
    final ws = Directory(
      widget.studentDir,
    ).parent.path; // .../<studentId>/<hash>
    final base = Directory(ws).parent.path; // .../<studentId>
    final base2 = Directory(base).parent.path; // .../WORKSPACE_DIR
    return p.join(base2, '.cache');
  }

  @override
  void initState() {
    super.initState();
    _initAudio();
    _loadSidecarIfAny();
    _buildWaveform(); // 비동기 진행
  }

  Future<void> _initAudio() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    await _player.setFilePath(widget.mediaPath);
    _duration = _player.duration ?? Duration.zero;

    _durSub = _player.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d ?? Duration.zero);
      _normalizeLoopOrder();
    });

    _posSub = _player.positionStream.listen((pos) async {
      if (!mounted) return;
      setState(() => _position = pos);

      if (_loopEnabled && _loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (b > Duration.zero && pos >= b) {
          await _player.seek(a);
        }
      }
    });

    _stateSub = _player.playerStateStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _buildWaveform() async {
    try {
      setState(() => _waveProgress = 0.05);
      final peaks = await WaveformCache.instance.loadOrBuild(
        mediaPath: widget.mediaPath,
        cacheDir: _cacheDir,
        cacheKey: widget.mediaHash,
        targetBars: 800,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _waveProgress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _peaks = peaks;
        _waveProgress = 1.0;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파형 생성 실패: $e')));
    }
  }

  Future<void> _loadSidecarIfAny() async {
    final f = File(widget.initialSidecar ?? _sidecarPath);
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map) {
        final m = Map<String, dynamic>.from(j);
        final a = (m['loopA'] ?? 0).toInt();
        final b = (m['loopB'] ?? 0).toInt();
        final sp = (m['speed'] ?? 1.0).toDouble();
        final posMs = (m['positionMs'] ?? 0).toInt();
        final mk = (m['markers'] as List?)?.cast<dynamic>() ?? const [];
        setState(() {
          _loopA = a > 0 ? Duration(milliseconds: a) : null;
          _loopB = b > 0 ? Duration(milliseconds: b) : null;
          _loopEnabled = (m['loopOn'] ?? false) == true;
          _speed = sp.clamp(0.5, 1.5);
          _markers
            ..clear()
            ..addAll(
              mk.whereType<Map>().map(
                (e) => MarkerPoint.fromJson(Map<String, dynamic>.from(e)),
              ),
            );
        });

        _normalizeLoopOrder();

        await _player.setSpeed(_speed);
        if (posMs > 0) {
          final d = Duration(milliseconds: posMs);
          if (_player.duration == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final dur = _player.duration;
              if (dur != null && d < dur) {
                await _player.seek(d);
              }
            });
          } else if (d < (_player.duration ?? Duration.zero)) {
            await _player.seek(d);
          }
        }
      }
    } catch (_) {
      /* ignore sidecar parse error */
    }
  }

  void _normalizeLoopOrder() {
    if (_loopA != null &&
        _loopB != null &&
        !_loopA!.isNegative &&
        !_loopB!.isNegative) {
      if (_player.duration == null || _player.duration == Duration.zero) return;
      final trackDur = _player.duration!;
      if (_loopA! >= _loopB!) {
        final two = const Duration(seconds: 2);
        final newB = ((_loopA! + two) < trackDur)
            ? _loopA! + two
            : (trackDur - const Duration(milliseconds: 1));
        setState(() => _loopB = newB);
      }
    }
  }

  Future<void> _saveSidecar({bool toast = true}) async {
    final m = {
      'studentId': widget.studentId,
      'mediaHash': widget.mediaHash,
      'speed': _speed,
      'loopA': _loopA?.inMilliseconds ?? 0,
      'loopB': _loopB?.inMilliseconds ?? 0,
      'loopOn': _loopEnabled,
      'positionMs': _position.inMilliseconds,
      'savedAt': DateTime.now().toIso8601String(),
      'media': p.basename(widget.mediaPath),
      'version': 'v1.87.0',
      'markers': _markers.map((e) => e.toJson()).toList(),
      'notes': '',
    };
    try {
      final f = File(_sidecarPath);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(m),
        flush: true,
      );
      if (toast && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('저장됨 (current.gtxsc)')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('저장 실패: $e')));
    }
  }

  void _debouncedSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 1200),
      () => _saveSidecar(toast: false),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    unawaited(_saveSidecar(toast: false));
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _seekBy(Duration delta) async {
    final now = _position;
    var target = now + delta;
    if (target < Duration.zero) target = Duration.zero;
    final dur = _player.duration ?? _duration;
    if (dur > Duration.zero && target > dur) target = dur;
    await _player.seek(target);
  }

  Future<void> _togglePlay() async {
    final playing = _player.playerState.playing;
    if (playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  void _quickLoopAround(Duration halfSpan) {
    final dur = _player.duration ?? _duration;
    if (dur == Duration.zero) return;
    final center = _position;
    var a = center - halfSpan;
    var b = center + halfSpan;
    if (a < Duration.zero) a = Duration.zero;
    if (b > dur) b = dur - const Duration(milliseconds: 1);
    setState(() {
      _loopA = a;
      _loopB = b;
      _loopEnabled = true;
    });
    _debouncedSave();
  }

  void _nudgeLoopEdge({required bool isA, required int deltaMs}) {
    if (_player.duration == null || _player.duration == Duration.zero) return;
    var a = _loopA;
    var b = _loopB;
    if (isA && a != null) {
      a += Duration(milliseconds: deltaMs);
      if (a < Duration.zero) a = Duration.zero;
      _loopA = a;
    } else if (!isA && b != null) {
      b += Duration(milliseconds: deltaMs);
      if (b > _player.duration!)
        b = _player.duration! - const Duration(milliseconds: 1);
      _loopB = b;
    }
    _normalizeLoopOrder();
    setState(() {});
    _debouncedSave();
  }

  void _addMarker() {
    final idx = _markers.length + 1;
    final label = 'M$idx';
    setState(() => _markers.add(MarkerPoint(_position, label)));
    _debouncedSave();
  }

  void _jumpToMarkerIndex(int i1based) async {
    final i = i1based - 1;
    if (i < 0 || i >= _markers.length) return;
    final d = _markers[i].t;
    await _player.seek(d);
  }

  void _deleteMarker(int index) {
    if (index < 0 || index >= _markers.length) return;
    setState(() => _markers.removeAt(index));
    _debouncedSave();
  }

  void _zoom(double factor) {
    // factor>1 => zoom in (viewWidth smaller)
    const minWidth = 0.02; // 2% (= 약 1/50)
    const maxWidth = 1.0;
    final centerT = (_duration.inMilliseconds == 0)
        ? 0.5
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    var newWidth = (_viewWidth / factor).clamp(minWidth, maxWidth);
    // center 유지하도록 viewStart 조정
    var newStart = (centerT - newWidth / 2).clamp(0.0, 1.0 - newWidth);
    setState(() {
      _viewWidth = newWidth;
      _viewStart = newStart;
    });
  }

  void _scrollTo(double start) {
    if (start < 0) start = 0;
    if (start > 1 - _viewWidth) start = 1 - _viewWidth;
    setState(() => _viewStart = start);
  }

  PreferredSizeWidget _buildTopBar(bool playing, String title) {
    return AppBar(
      title: Text('스마트 미디어 플레이어 — $title'),
      actions: [
        if (_waveProgress < 1.0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Center(
              child: Text('파형 ${(_waveProgress * 100).toStringAsFixed(0)}%'),
            ),
          ),
        Tooltip(
          message: '저장 (S)',
          child: IconButton(
            onPressed: _saveSidecar,
            icon: const Icon(Icons.save),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.playerState.playing;
    final title = p.basename(widget.mediaPath);

    // 뷰어 핫키 매핑
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.space): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.comma): const _SeekIntent(-1000),
        LogicalKeySet(LogicalKeyboardKey.period): const _SeekIntent(1000),
        LogicalKeySet(LogicalKeyboardKey.keyJ): const _SeekIntent(-10000),
        LogicalKeySet(LogicalKeyboardKey.keyL): const _SeekIntent(10000),
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.keyL):
            const _ToggleLoopIntent(),
        LogicalKeySet(LogicalKeyboardKey.keyA): const _SetLoopIntent(true),
        LogicalKeySet(LogicalKeyboardKey.keyB): const _SetLoopIntent(false),
        LogicalKeySet(LogicalKeyboardKey.keyS): const _SaveIntent(),
        LogicalKeySet(LogicalKeyboardKey.keyM): const _AddMarkerIntent(),
        LogicalKeySet(LogicalKeyboardKey.keyZ): const _QuickLoopIntent(2000),
        LogicalKeySet(LogicalKeyboardKey.keyX): const _QuickLoopIntent(5000),
        LogicalKeySet(LogicalKeyboardKey.keyC): const _QuickLoopIntent(10000),
        LogicalKeySet(LogicalKeyboardKey.equal): const _ZoomIntent(true), // =
        LogicalKeySet(LogicalKeyboardKey.minus): const _ZoomIntent(false), // -
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.comma):
            const _NudgeIntent(true, -100),
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.period):
            const _NudgeIntent(false, 100),

        // Alt+1..9 → 마커 점프
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
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _togglePlay();
              return null;
            },
          ),
          _SeekIntent: CallbackAction<_SeekIntent>(
            onInvoke: (i) {
              _seekBy(Duration(milliseconds: i.deltaMs));
              return null;
            },
          ),
          _ToggleLoopIntent: CallbackAction<_ToggleLoopIntent>(
            onInvoke: (_) {
              setState(() => _loopEnabled = !_loopEnabled);
              _debouncedSave();
              return null;
            },
          ),
          _SetLoopIntent: CallbackAction<_SetLoopIntent>(
            onInvoke: (i) {
              setState(() {
                if (i.isA) {
                  _loopA = _position;
                } else {
                  _loopB = _position;
                }
                _normalizeLoopOrder();
              });
              _debouncedSave();
              return null;
            },
          ),
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              _saveSidecar();
              return null;
            },
          ),
          _AddMarkerIntent: CallbackAction<_AddMarkerIntent>(
            onInvoke: (_) {
              _addMarker();
              return null;
            },
          ),
          _QuickLoopIntent: CallbackAction<_QuickLoopIntent>(
            onInvoke: (i) {
              _quickLoopAround(Duration(milliseconds: i.halfSpanMs));
              return null;
            },
          ),
          _ZoomIntent: CallbackAction<_ZoomIntent>(
            onInvoke: (i) {
              _zoom(i.zoomIn ? 1.25 : 0.8);
              return null;
            },
          ),
          _NudgeIntent: CallbackAction<_NudgeIntent>(
            onInvoke: (i) {
              _nudgeLoopEdge(isA: i.isA, deltaMs: i.deltaMs);
              return null;
            },
          ),
          _JumpMarkerIntent: CallbackAction<_JumpMarkerIntent>(
            onInvoke: (i) {
              _jumpToMarkerIndex(i.i1based);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: _buildTopBar(playing, title),
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Progress + Quick seek
                  Row(
                    children: [
                      Text('${_fmt(_position)} / ${_fmt(_duration)}'),
                      const Spacer(),
                      Tooltip(
                        message: '−10s (J)',
                        child: IconButton(
                          onPressed: () =>
                              _seekBy(const Duration(seconds: -10)),
                          icon: const Icon(Icons.replay_10),
                        ),
                      ),
                      Tooltip(
                        message: '−1s (,)',
                        child: IconButton(
                          onPressed: () => _seekBy(const Duration(seconds: -1)),
                          icon: const Icon(Icons.keyboard_arrow_left),
                        ),
                      ),
                      Tooltip(
                        message: '+1s (.)',
                        child: IconButton(
                          onPressed: () => _seekBy(const Duration(seconds: 1)),
                          icon: const Icon(Icons.keyboard_arrow_right),
                        ),
                      ),
                      Tooltip(
                        message: '+10s (L)',
                        child: IconButton(
                          onPressed: () => _seekBy(const Duration(seconds: 10)),
                          icon: const Icon(Icons.forward_10),
                        ),
                      ),
                    ],
                  ),
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
                      await _player.seek(d);
                    },
                  ),

                  const SizedBox(height: 8),

                  // Transport + Speed + QuickLoop + Zoom
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _togglePlay,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        label: Text(playing ? '일시정지 (Space)' : '재생 (Space)'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => _player.seek(Duration.zero),
                        icon: const Icon(Icons.replay),
                        label: const Text('처음으로'),
                      ),
                      const Spacer(),
                      // Quick loop
                      Wrap(
                        spacing: 6,
                        children: [
                          Tooltip(
                            message: '퀵루프 ±2s (Z)',
                            child: OutlinedButton(
                              onPressed: () =>
                                  _quickLoopAround(const Duration(seconds: 2)),
                              child: const Text('±2s'),
                            ),
                          ),
                          Tooltip(
                            message: '퀵루프 ±5s (X)',
                            child: OutlinedButton(
                              onPressed: () =>
                                  _quickLoopAround(const Duration(seconds: 5)),
                              child: const Text('±5s'),
                            ),
                          ),
                          Tooltip(
                            message: '퀵루프 ±10s (C)',
                            child: OutlinedButton(
                              onPressed: () =>
                                  _quickLoopAround(const Duration(seconds: 10)),
                              child: const Text('±10s'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      // Speed
                      Row(
                        children: [
                          const Text('속도'),
                          const SizedBox(width: 8),
                          DropdownButton<double>(
                            value: _speed,
                            items: const [
                              DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                              DropdownMenuItem(
                                value: 0.75,
                                child: Text('0.75x'),
                              ),
                              DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                              DropdownMenuItem(
                                value: 1.25,
                                child: Text('1.25x'),
                              ),
                              DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                            ],
                            onChanged: (v) async {
                              if (v == null) return;
                              setState(() => _speed = v);
                              await _player.setSpeed(v);
                              _debouncedSave();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      // Zoom
                      Row(
                        children: [
                          Tooltip(
                            message: '줌아웃 (-)',
                            child: IconButton(
                              onPressed: () => _zoom(0.8),
                              icon: const Icon(Icons.zoom_out),
                            ),
                          ),
                          Tooltip(
                            message: '줌인 (=)',
                            child: IconButton(
                              onPressed: () => _zoom(1.25),
                              icon: const Icon(Icons.zoom_in),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const Divider(height: 24),

                  // Waveform section with viewport + markers
                  SizedBox(
                    height: 120,
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
                            duration: _duration,
                            position: _position,
                            loopA: _loopA,
                            loopB: _loopB,
                            loopOn: _loopEnabled,
                            markers: _markers.map((e) => e.t).toList(),
                            viewStart: _viewStart,
                            viewWidth: _viewWidth,
                            onSeek: (d) async => _player.seek(d),
                          ),
                  ),

                  // Mini-map / viewport slider
                  if (_duration > Duration.zero) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text('뷰'),
                        Expanded(
                          child: Slider(
                            value: _viewStart,
                            min: 0,
                            max: (1 - _viewWidth).clamp(0.0, 1.0),
                            onChanged: (v) => _scrollTo(v),
                          ),
                        ),
                        Text('${(_viewWidth * 100).round()}%'),
                      ],
                    ),
                  ],

                  const SizedBox(height: 12),

                  // A/B loop + nudge
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () {
                          setState(() => _loopA = _position);
                          _normalizeLoopOrder();
                          _debouncedSave();
                        },
                        child: Text(
                          _loopA == null
                              ? 'A 지점 (A)'
                              : 'A 재설정 (${_fmt(_loopA!)})',
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () {
                          setState(() => _loopB = _position);
                          _normalizeLoopOrder();
                          _debouncedSave();
                        },
                        child: Text(
                          _loopB == null
                              ? 'B 지점 (B)'
                              : 'B 재설정 (${_fmt(_loopB!)})',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        children: [
                          const Text('미세이동'),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'A -100ms (Shift+,)',
                            child: IconButton(
                              onPressed: () =>
                                  _nudgeLoopEdge(isA: true, deltaMs: -100),
                              icon: const Icon(
                                Icons.keyboard_double_arrow_left,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: 'B +100ms (Shift+.)',
                            child: IconButton(
                              onPressed: () =>
                                  _nudgeLoopEdge(isA: false, deltaMs: 100),
                              icon: const Icon(
                                Icons.keyboard_double_arrow_right,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Row(
                        children: [
                          Switch(
                            value: _loopEnabled,
                            onChanged: (v) {
                              setState(() => _loopEnabled = v);
                              _debouncedSave();
                            },
                          ),
                          const Text('루프 (Shift+L)'),
                        ],
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _loopA = null;
                            _loopB = null;
                            _loopEnabled = false;
                          });
                          _debouncedSave();
                        },
                        child: const Text('루프 해제'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Marker chips/list
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _addMarker,
                        icon: const Icon(Icons.add),
                        label: const Text('마커 추가 (M)'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (int i = 0; i < _markers.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    label: Text(
                                      '${_markers[i].label} ${_fmt(_markers[i].t)}',
                                    ),
                                    onPressed: () =>
                                        _player.seek(_markers[i].t),
                                    onDeleted: () => _deleteMarker(i),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),
                  Text(
                    '사이드카: ${p.basename(_sidecarPath)}  •  폴더: ${widget.studentDir}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Intents ----
class _SeekIntent extends Intent {
  final int deltaMs;
  const _SeekIntent(this.deltaMs);
}

class _ToggleLoopIntent extends Intent {
  const _ToggleLoopIntent();
}

class _SetLoopIntent extends Intent {
  final bool isA;
  const _SetLoopIntent(this.isA);
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _AddMarkerIntent extends Intent {
  const _AddMarkerIntent();
}

class _QuickLoopIntent extends Intent {
  final int halfSpanMs;
  const _QuickLoopIntent(this.halfSpanMs);
}

class _ZoomIntent extends Intent {
  final bool zoomIn;
  const _ZoomIntent(this.zoomIn);
}

class _NudgeIntent extends Intent {
  final bool isA;
  final int deltaMs;
  const _NudgeIntent(this.isA, this.deltaMs);
}

class _JumpMarkerIntent extends Intent {
  final int i1based;
  const _JumpMarkerIntent(this.i1based);
}
