// v1.96.3 | Speed UI: presets(50~120%) + ±5% nudge buttons, layout polish
// - 속도 프리셋 버튼 50/60/70/80/90/100/110/120 추가
// - 속도 슬라이더 좌우에 -/+ 버튼(각 5%)
// - Speed 섹션 UI/배치 정돈(현재 값 배지 표시)
// - 기타: 내부 _nudgeSpeed() 유틸 추가, _setSpeed() 재사용

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'waveform/waveform_cache.dart';
import 'widgets/waveform_view.dart';

// (선택) 비디오 컨트롤러가 프로젝트에 이미 존재한다고 가정
// ignore: unnecessary_import
import 'package:video_player/video_player.dart';

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
    final v = c.value; // 0xAARRGGBB
    final r = ((v >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final g = ((v >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final b = (v & 0xFF).toRadixString(16).padLeft(2, '0');
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

class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;

  // 키보드 포커스
  final FocusNode _focusNode = FocusNode(debugLabel: 'SMPFocus');

  // 재생 파라미터
  double _speed = 1.0; // 0.50 ~ 1.50
  int _pitchSemi = 0; // -7 .. +7
  bool _pitchSupported = false;
  bool _pitchToastShown = false;
  bool _pitchChecked = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;

  int _loopRepeat = 4;
  int _loopRemaining = -1;

  // 시작점
  Duration _startCue = Duration.zero;

  // 마커
  final List<MarkerPoint> _markers = [];

  // 자동 저장
  Timer? _saveDebounce;

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

  // 비디오 (옵션)
  bool _isVideo = false;
  VideoPlayerController? _video;

  String get _sidecarPath => p.join(widget.studentDir, 'current.gtxsc');

  String get _cacheDir {
    final ws = Directory(widget.studentDir).parent.path;
    final base = Directory(ws).parent.path;
    final base2 = Directory(base).parent.path;
    return p.join(base2, '.cache');
  }

  Duration _clampDuration(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _pitchSupported = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
    _detectIsVideo();
    _initAudio().then((_) {
      // ✅ 오디오 초기화 완료 후
      if (mounted) _buildWaveform(); // ✅ 그 다음 파형 생성
    });
    _initVideoIfAny();
    _loadSidecarIfAny();
  }

  void _detectIsVideo() {
    final ext = p.extension(widget.mediaPath).toLowerCase();
    _isVideo = const ['.mp4', '.mov', '.mkv', '.webm', '.avi'].contains(ext);
  }

  Future<void> _initVideoIfAny() async {
    if (!_isVideo) return;
    try {
      _video = VideoPlayerController.file(File(widget.mediaPath));
      await _video!.initialize();
      await _video!.setLooping(false);
      // 오디오는 just_audio 주도 → 비디오 mute
      await _video!.setVolume(0.0);
      setState(() {});
    } catch (e) {
      // ignore
    }
  }

  Future<void> _initAudio() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    try {
      await _player.setFilePath(widget.mediaPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오디오 로드 실패: $e')));
      return;
    }

    await _verifyPitchSupport();

    _duration = _player.duration ?? Duration.zero;

    _durSub = _player.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d ?? Duration.zero);
      _normalizeLoopOrder();
    });

    _posSub = _player.positionStream.listen((pos) async {
      if (!mounted) return;
      setState(() => _position = pos);

      // 비디오 동기화
      if (_isVideo && _video != null && _video!.value.isInitialized) {
        final vpos = await _video!.position;
        if (vpos != null && (vpos - pos).inMilliseconds.abs() > 60) {
          unawaited(_video!.seekTo(pos));
        }
      }

      // 루프 동작
      if (_loopEnabled && _loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (pos < a) {
          await _seekBoth(a);
          return;
        }
        if (b > Duration.zero && pos >= b) {
          if (_loopRemaining < 0) {
            _loopRemaining = _loopRepeat;
          } else {
            _loopRemaining -= 1;
          }
          if (_loopRemaining <= 0) {
            setState(() {
              _loopEnabled = false;
            });
            await _pauseBoth();
            _debouncedSave();
            return;
          }
          await _seekBoth(a);
          return;
        }
      }

      // 트랙 끝 처리
      final dur = _player.duration ?? Duration.zero;
      if (!_loopEnabled && dur > Duration.zero && pos >= dur) {
        await _pauseBoth();
        await _seekBoth(_clampDuration(_startCue, Duration.zero, dur));
      }
    });

    _stateSub = _player.playerStateStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _verifyPitchSupport() async {
    try {
      await _player.setPitch(1.001);
      await _player.setPitch(1.0);
      if (!mounted) return;
      setState(() {
        _pitchSupported = true;
        _pitchChecked = true;
      });
      await _applyTempoPitch();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pitchSupported = false;
        _pitchChecked = true;
      });
    }
  }

  Future<void> _buildWaveform() async {
    try {
      setState(() => _waveProgress = 0.05);

      // 곡 길이에 비례 (권장: 256~512 bars/sec)
      final secs = (_duration.inMilliseconds / 1000).clamp(
        1,
        60 * 60 * 3,
      ); // 안전: 최대 3시간
      final target = (secs * 512).round().clamp(8192, 120000); // 상한 12만

      final (left, right) = await WaveformCache.instance.loadOrBuildStereo(
        mediaPath: widget.mediaPath,
        cacheDir: _cacheDir,
        cacheKey: widget.mediaHash,
        targetBars: target, // ✅ 동적으로 크게
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
        final ps = (m['pitchSemi'] ?? 0).toInt();
        final rpRaw = (m['loopRepeat'] ?? 4).toInt();
        final sc = (m['startCueMs'] ?? 0).toInt();

        setState(() {
          _loopA = a > 0 ? Duration(milliseconds: a) : null;
          _loopB = b > 0 ? Duration(milliseconds: b) : null;
          _loopEnabled = (m['loopOn'] ?? false) == true;
          _speed = sp.clamp(0.5, 1.5);
          _loopRepeat = rpRaw.clamp(1, 200);
          _loopRemaining = -1;
          _pitchSemi = ps.clamp(-7, 7);
          _startCue = _clampDuration(
            Duration(milliseconds: sc),
            Duration.zero,
            _duration,
          );

          _markers
            ..clear()
            ..addAll(
              mk.whereType<Map>().map(
                (e) => MarkerPoint.fromJson(Map<String, dynamic>.from(e)),
              ),
            );
        });

        _normalizeLoopOrder();
        await _applyTempoPitch();

        if (posMs > 0) {
          final d = Duration(milliseconds: posMs);
          final dur = _player.duration;
          if (dur == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final dd = _player.duration;
              if (dd != null && d < dd) {
                await _seekBoth(d);
              }
            });
          } else if (d < dur) {
            await _seekBoth(d);
          }
        }
      }
    } catch (_) {}
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
      'pitchSemi': _pitchSemi,
      'loopA': _loopA?.inMilliseconds ?? 0,
      'loopB': _loopB?.inMilliseconds ?? 0,
      'loopOn': _loopEnabled,
      'loopRepeat': _loopRepeat,
      'positionMs': _position.inMilliseconds,
      'startCueMs': _startCue.inMilliseconds,
      'savedAt': DateTime.now().toIso8601String(),
      'media': p.basename(widget.mediaPath),
      'version': 'v1.96.3',
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
        ).showSnackBar(const SnackBar(content: Text('자동 저장됨')));
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
      const Duration(milliseconds: 800),
      () => _saveSidecar(toast: false),
    );
  }

  double _semiToPitchRatio(int semi) => math.pow(2, semi / 12).toDouble();

  Future<void> _applyTempoPitch() async {
    try {
      await _player.setSpeed(_speed);
    } catch (_) {}
    final ratio = _semiToPitchRatio(_pitchSemi);
    if (_pitchSupported) {
      try {
        await _player.setPitch(ratio);
      } catch (_) {
        setState(() => _pitchSupported = false);
      }
    }
    if (!_pitchChecked) return;
    if (!_pitchSupported && !_pitchToastShown && mounted) {
      _pitchToastShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이 환경에선 키(피치) 변경이 지원되지 않습니다.')),
      );
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    unawaited(_saveSidecar(toast: false));
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    _video?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _seekBoth(Duration d) async {
    await _player.seek(d);
    if (_isVideo && _video != null && _video!.value.isInitialized) {
      await _video!.seekTo(d);
    }
  }

  Future<void> _playBoth() async {
    if (_isVideo && _video != null && _video!.value.isInitialized) {
      await _video!.play();
    }
    await _player.play();
  }

  Future<void> _pauseBoth() async {
    if (_isVideo && _video != null && _video!.value.isInitialized) {
      await _video!.pause();
    }
    await _player.pause();
  }

  Future<void> _seekBy(Duration delta) async {
    final now = _position;
    var target = now + delta;
    if (target < Duration.zero) target = Duration.zero;
    final dur = _player.duration ?? _duration;
    if (dur > Duration.zero && target > dur) target = dur;
    await _seekBoth(target);
  }

  Future<void> _spacePlayBehavior() async {
    final playing = _player.playerState.playing;
    if (playing) {
      await _pauseBoth();
    } else {
      final d = _clampDuration(_startCue, Duration.zero, _duration);
      await _seekBoth(d);
      await _playBoth();
    }
  }

  void _syncStartCueToAIfPossible() {
    if (_loopA != null) {
      setState(() {
        _startCue = _clampDuration(_loopA!, Duration.zero, _duration);
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

  void _loopBetweenNearestMarkers() {
    if (_markers.length < 2 || _duration == Duration.zero) return;
    final pos = _position.inMilliseconds;
    final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));

    MarkerPoint? left;
    MarkerPoint? right;
    for (final m in sorted) {
      if (m.t.inMilliseconds <= pos) {
        left = m;
      } else {
        right ??= m;
      }
      if (left != null && right != null) break;
    }
    left ??= sorted.first;
    right ??= sorted.last;
    var a = left.t;
    var b = right.t - const Duration(milliseconds: 1);
    if (b <= a) b = left.t + const Duration(milliseconds: 500);
    setState(() {
      _loopA = a;
      _loopB = b;
      _loopEnabled = true;
      _loopRemaining = -1;
      _startCue = _clampDuration(a, Duration.zero, _duration);
    });
    _debouncedSave();
  }

  void _addMarker() {
    final idx = _markers.length + 1;
    final label = 'M$idx';
    setState(() => _markers.add(MarkerPoint(_position, label)));
    _debouncedSave();
  }

  void _editMarker(int index) async {
    if (index < 0 || index >= _markers.length) return;
    final m = _markers[index];
    final labelCtl = TextEditingController(text: m.label);
    final noteCtl = TextEditingController(text: m.note ?? '');
    final colorCtl = TextEditingController(
      text: m.color == null ? '' : MarkerPoint._colorToHex(m.color!),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('마커 편집'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtl,
              decoration: const InputDecoration(labelText: '라벨'),
            ),
            TextField(
              controller: noteCtl,
              decoration: const InputDecoration(labelText: '노트(선택)'),
            ),
            TextField(
              controller: colorCtl,
              decoration: const InputDecoration(
                labelText: '색상 HEX (예: #FF7043)',
              ),
            ),
          ],
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
        m.label = labelCtl.text.trim().isEmpty ? m.label : labelCtl.text.trim();
        m.note = noteCtl.text.trim().isEmpty ? null : noteCtl.text.trim();
        m.color = MarkerPoint._tryParseColor(colorCtl.text.trim());
      });
      _debouncedSave();
    }
  }

  Future<void> _jumpToMarkerIndex(int i1based) async {
    final i = i1based - 1;
    if (i < 0 || i >= _markers.length) return;
    final d = _markers[i].t;
    // 경계 끌림 방지: 조금 안쪽으로
    final pad = const Duration(milliseconds: 5);
    final dur = _player.duration ?? _duration;
    final target = _clampDuration(d + pad, Duration.zero, dur);
    setState(() => _loopRemaining = -1);
    await _seekBoth(target);
  }

  Future<void> _jumpPrevNextMarker({required bool next}) async {
    if (_markers.isEmpty || _duration == Duration.zero) return;
    final nowMs = _position.inMilliseconds;
    final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));
    final pad = const Duration(milliseconds: 5);
    if (next) {
      for (final m in sorted) {
        if (m.t.inMilliseconds > nowMs + 10) {
          setState(() => _loopRemaining = -1);
          await _seekBoth(m.t + pad);
          return;
        }
      }
      setState(() => _loopRemaining = -1);
      await _seekBoth(sorted.last.t + pad);
    } else {
      for (var i = sorted.length - 1; i >= 0; i--) {
        if (sorted[i].t.inMilliseconds < nowMs - 10) {
          setState(() => _loopRemaining = -1);
          await _seekBoth(sorted[i].t + pad);
          return;
        }
      }
      setState(() => _loopRemaining = -1);
      await _seekBoth(sorted.first.t + pad);
    }
  }

  void _deleteMarker(int index) {
    if (index < 0 || index >= _markers.length) return;
    setState(() => _markers.removeAt(index));
    _debouncedSave();
  }

  void _reorderMarkers(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _markers.removeAt(oldIndex);
      _markers.insert(newIndex, item);
    });
    _debouncedSave();
  }

  void _openMarkerSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SizedBox(
          height: 420,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('마커 관리', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: _markers.length,
                    onReorder: _reorderMarkers,
                    buildDefaultDragHandles: false,
                    itemBuilder: (c, i) {
                      final m = _markers[i];
                      return ListTile(
                        key: ValueKey('mk_$i'),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_indicator),
                        ),
                        title: Text('${m.label}  •  ${_fmt(m.t)}'),
                        subtitle: (m.note?.isNotEmpty ?? false)
                            ? Text(m.note!)
                            : null,
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: '점프',
                              icon: const Icon(Icons.my_location),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _seekBoth(m.t);
                              },
                            ),
                            IconButton(
                              tooltip: '편집',
                              icon: const Icon(Icons.edit),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _editMarker(i);
                              },
                            ),
                            IconButton(
                              tooltip: '삭제',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () {
                                setState(() => _markers.removeAt(i));
                                _debouncedSave();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('닫기'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
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
              Text('시작점에서 재생/일시정지: Space'),
              Text('이동: , / .  (±1s),  J / L (±10s)'),
              Text('루프 토글: Shift+L  •  E/D: A/B 지정'),
              Text('마커 추가: M  •  인접 마커 루프: Shift+M'),
              Text('마커 점프: Alt+1..9  •  이전/다음: Alt+←/→'),
              Text('줌: = / -'),
              Text('속도 프리셋: 5=0.5x,6=0.6x,7=0.7x,8=0.8x,9=0.9x,0=1.0x'),
              Text('키(반음) +1/-1/리셋: Alt+↑ / Alt+↓ / Alt+0'),
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

  void _scrollTo(double start) {
    if (start < 0) start = 0;
    if (start > 1 - _viewWidth) start = 1 - _viewWidth;
    setState(() => _viewStart = start);
  }

  void _pitchDelta(int d) async {
    if (!_pitchSupported) {
      if (!_pitchToastShown && mounted) {
        _pitchToastShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이 환경에선 키(피치) 변경이 지원되지 않습니다.')),
        );
      }
      return;
    }
    setState(() {
      _pitchSemi = (_pitchSemi + d).clamp(-7, 7);
    });
    await _applyTempoPitch();
    _debouncedSave();
  }

  void _pitchReset() async {
    if (!_pitchSupported) return;
    setState(() => _pitchSemi = 0);
    await _applyTempoPitch();
    _debouncedSave();
  }

  // 속도 프리셋/조절
  Future<void> _setSpeed(double v) async {
    setState(() => _speed = double.parse(v.clamp(0.5, 1.5).toStringAsFixed(2)));
    await _applyTempoPitch();
    _debouncedSave();
  }

  Future<void> _nudgeSpeed(int deltaPercent) async {
    // deltaPercent: +5 or -5
    final step = deltaPercent / 100.0;
    final v = (_speed + step);
    await _setSpeed(v);
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.playerState.playing;
    final title = p.basename(widget.mediaPath);

    final markerDurations = _markers.map((e) => e.t).toList();
    final markerLabels = _markers.map((e) => e.label).toList();
    final markerColors = _markers.map((e) => e.color).toList();

    // 프리셋 값들 (50%~120%)
    const speedPresets = <double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2];

    return Listener(
      onPointerDown: (_) {
        if (!_focusNode.hasFocus) _focusNode.requestFocus();
      },
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          // Space
          LogicalKeySet(LogicalKeyboardKey.space):
              const _PlayFromStartOrPauseIntent(),
          // Seek
          LogicalKeySet(LogicalKeyboardKey.comma): const _SeekIntent(-1000),
          LogicalKeySet(LogicalKeyboardKey.period): const _SeekIntent(1000),
          LogicalKeySet(LogicalKeyboardKey.keyJ): const _SeekIntent(-10000),
          LogicalKeySet(LogicalKeyboardKey.keyL): const _SeekIntent(10000),
          // Loop
          LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.keyL):
              const _ToggleLoopIntent(),
          // E/D → A/B
          LogicalKeySet(LogicalKeyboardKey.keyE): const _SetLoopIntent(true),
          LogicalKeySet(LogicalKeyboardKey.keyD): const _SetLoopIntent(false),
          // Markers
          LogicalKeySet(LogicalKeyboardKey.keyM): const _AddMarkerIntent(),
          LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.keyM):
              const _LoopBetweenMarkersIntent(),
          // Zoom
          LogicalKeySet(LogicalKeyboardKey.equal): const _ZoomIntent(true),
          LogicalKeySet(LogicalKeyboardKey.minus): const _ZoomIntent(false),
          // Markers jump
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
          // Pitch
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowUp):
              const _PitchUpIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown):
              const _PitchDownIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit0):
              const _PitchResetIntent(),
          // Speed presets: 5..0
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
            _SeekIntent: CallbackAction<_SeekIntent>(
              onInvoke: (i) {
                _seekBy(Duration(milliseconds: i.deltaMs));
                return null;
              },
            ),
            _ToggleLoopIntent: CallbackAction<_ToggleLoopIntent>(
              onInvoke: (_) {
                setState(() {
                  _loopEnabled = !_loopEnabled;
                  _loopRemaining = -1;
                  if (_loopEnabled) _syncStartCueToAIfPossible();
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
            _LoopBetweenMarkersIntent:
                CallbackAction<_LoopBetweenMarkersIntent>(
                  onInvoke: (_) {
                    _loopBetweenNearestMarkers();
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
            _PitchResetIntent: CallbackAction<_PitchResetIntent>(
              onInvoke: (_) {
                _pitchReset();
                return null;
              },
            ),
            _SpeedPresetIntent: CallbackAction<_SpeedPresetIntent>(
              onInvoke: (i) {
                _setSpeed(i.value);
                return null;
              },
            ),
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
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
                  IconButton(
                    tooltip: '단축키 안내',
                    onPressed: _showHotkeys,
                    icon: const Icon(Icons.help_outline),
                  ),
                ],
              ),
              body: LayoutBuilder(
                builder: (ctx, c) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight - 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 비디오 미리보기 (옵션)
                          if (_isVideo &&
                              _video != null &&
                              _video!.value.isInitialized) ...[
                            Center(
                              child: SizedBox(
                                width: c.maxWidth,
                                // 화면 크기에 비례해 커지며, 잘리지 않도록 contain
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: SizedBox(
                                    width: c.maxWidth,
                                    child: AspectRatio(
                                      aspectRatio:
                                          _video!.value.aspectRatio == 0
                                          ? (16 / 9)
                                          : _video!.value.aspectRatio,
                                      child: VideoPlayer(_video!),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],

                          // Progress + Quick seek
                          Row(
                            children: [
                              Text('${_fmt(_position)} / ${_fmt(_duration)}'),
                              const Spacer(),
                              IconButton(
                                tooltip: '−10s (J)',
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: -10)),
                                icon: const Icon(Icons.replay_10),
                              ),
                              IconButton(
                                tooltip: '−1s (,)',
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: -1)),
                                icon: const Icon(Icons.keyboard_arrow_left),
                              ),
                              IconButton(
                                tooltip: '+1s (.)',
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: 1)),
                                icon: const Icon(Icons.keyboard_arrow_right),
                              ),
                              IconButton(
                                tooltip: '+10s (L)',
                                onPressed: () =>
                                    _seekBy(const Duration(seconds: 10)),
                                icon: const Icon(Icons.forward_10),
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
                              await _seekBoth(d);
                            },
                          ),

                          const SizedBox(height: 8),

                          // Transport + Speed + Pitch + Repeat + Zoom
                          Wrap(
                            runSpacing: 8,
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: _spacePlayBehavior,
                                icon: Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                ),
                                label: const Text('시작점 재생/정지 (Space)'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  await _pauseBoth();
                                  await _seekBoth(
                                    _clampDuration(
                                      _startCue,
                                      Duration.zero,
                                      _duration,
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.stop),
                                label: const Text('정지(시작점으로)'),
                              ),
                              OutlinedButton(
                                onPressed: () {
                                  setState(
                                    () => _startCue = _clampDuration(
                                      _position,
                                      Duration.zero,
                                      _duration,
                                    ),
                                  );
                                  _debouncedSave();
                                },
                                child: const Text('시작점=현재'),
                              ),
                              OutlinedButton(
                                onPressed: () {
                                  if (_loopA != null) {
                                    setState(
                                      () => _startCue = _clampDuration(
                                        _loopA!,
                                        Duration.zero,
                                        _duration,
                                      ),
                                    );
                                    _debouncedSave();
                                  }
                                },
                                child: const Text('시작점=A'),
                              ),

                              // ===== Speed (reworked) =====
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 360,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 제목 + 현재값 배지
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('속도'),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Theme.of(
                                                context,
                                              ).dividerColor,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            '${(_speed * 100).round()}% (${_speed.toStringAsFixed(2)}x)',
                                          ),
                                        ),
                                        const Spacer(),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    // -5%  [Slider]  +5%
                                    Row(
                                      children: [
                                        IconButton(
                                          tooltip: '속도 -5%',
                                          onPressed: () => _nudgeSpeed(-5),
                                          icon: const Icon(Icons.remove),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: _speed,
                                            min: 0.5,
                                            max: 1.5,
                                            divisions: 100,
                                            label:
                                                '${_speed.toStringAsFixed(2)}x',
                                            onChanged: (v) => _setSpeed(v),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '속도 +5%',
                                          onPressed: () => _nudgeSpeed(5),
                                          icon: const Icon(Icons.add),
                                        ),
                                      ],
                                    ),
                                    // 프리셋 버튼들 (50~120%)
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (final v in speedPresets)
                                          _SpeedPresetButton(
                                            value: v,
                                            selected:
                                                (v - _speed).abs() < 0.011,
                                            onTap: () => _setSpeed(v),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              // Pitch
                              Opacity(
                                opacity: _pitchSupported ? 1.0 : 0.5,
                                child: IgnorePointer(
                                  ignoring: !_pitchSupported,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text('키'),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _pitchDelta(-1),
                                        icon: const Icon(Icons.remove),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).dividerColor,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          '${_pitchSemi >= 0 ? '+' : ''}$_pitchSemi',
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _pitchDelta(1),
                                        icon: const Icon(Icons.add),
                                      ),
                                      TextButton(
                                        onPressed: _pitchReset,
                                        child: const Text('리셋'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // Loop Repeat
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('반복'),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 72,
                                    child: TextField(
                                      controller: TextEditingController(
                                        text: _loopRepeat.toString(),
                                      ),
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      onSubmitted: (v) {
                                        final parsed = int.tryParse(v.trim());
                                        if (parsed == null ||
                                            parsed < 1 ||
                                            parsed > 200) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                '반복 횟수는 1~200 사이의 정수여야 합니다.',
                                              ),
                                            ),
                                          );
                                          return;
                                        }
                                        setState(() {
                                          _loopRepeat = parsed;
                                          _loopRemaining = -1;
                                        });
                                        _debouncedSave();
                                      },
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_loopEnabled && _loopRemaining >= 0) ...[
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

                              // Zoom
                              IconButton(
                                tooltip: '줌아웃 (-)',
                                onPressed: () => _zoom(0.8),
                                icon: const Icon(Icons.zoom_out),
                              ),
                              IconButton(
                                tooltip: '줌인 (=)',
                                onPressed: () => _zoom(1.25),
                                icon: const Icon(Icons.zoom_in),
                              ),
                            ],
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
                                    // Wave area
                                    onSeek: (d) async {
                                      // 클릭 → 루프 OFF + seek + 시작점 동기화
                                      setState(() {
                                        _loopEnabled = false;
                                        _loopRemaining = -1;
                                        _startCue = _clampDuration(
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
                                      final B = b >= a ? b : a;
                                      setState(() {
                                        _loopA = A;
                                        _loopB =
                                            (B -
                                            const Duration(milliseconds: 1));
                                        if (_loopB! <= _loopA!) {
                                          _loopB =
                                              A +
                                              const Duration(milliseconds: 500);
                                        }
                                        _loopEnabled = true;
                                        _loopRemaining = -1;
                                        _startCue = _clampDuration(
                                          A,
                                          Duration.zero,
                                          _duration,
                                        );
                                        _selectStart = null;
                                        _selectEnd = null;
                                      });
                                      _debouncedSave();
                                    },
                                    // Rail
                                    markerRailHeight: 44,
                                    startCue: _startCue,
                                    onStartCueChanged: (d) {
                                      setState(() {
                                        _startCue = _clampDuration(
                                          d,
                                          Duration.zero,
                                          _duration,
                                        );
                                      });
                                      _debouncedSave();
                                    },
                                    onRailTapToSeek: (d) async {
                                      // 레일 탭: 시작점 이동 + seek (루프 상태 유지)
                                      await _seekBoth(d);
                                    },
                                    // Marker drag
                                    onMarkerDragStart: (i) {},
                                    onMarkerDragUpdate: (i, d) {
                                      setState(() {
                                        _markers[i].t = _clampDuration(
                                          d,
                                          Duration.zero,
                                          _duration,
                                        );
                                      });
                                    },
                                    onMarkerDragEnd: (i, d) {
                                      _debouncedSave();
                                    },
                                    // AB handle drag
                                    onLoopAChanged: (d) {
                                      setState(() {
                                        _loopA = _clampDuration(
                                          d,
                                          Duration.zero,
                                          _duration,
                                        );
                                        _normalizeLoopOrder();
                                        _loopRemaining = -1;
                                        if (_loopEnabled) {
                                          _syncStartCueToAIfPossible(); // ✅ braces
                                        }
                                      });
                                      _debouncedSave();
                                    },
                                    onLoopBChanged: (d) {
                                      setState(() {
                                        _loopB = _clampDuration(
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

                          // A/B & Loop
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton(
                                onPressed: () => _setLoopPoint(isA: true),
                                child: Text(
                                  _loopA == null
                                      ? 'A 지점 (E)'
                                      : 'A 재설정 (${_fmt(_loopA!)})',
                                ),
                              ),
                              OutlinedButton(
                                onPressed: () => _setLoopPoint(isA: false),
                                child: Text(
                                  _loopB == null
                                      ? 'B 지점 (D)'
                                      : 'B 재설정 (${_fmt(_loopB!)})',
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
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
                                  const Text('루프 (Shift+L)'),
                                ],
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _loopA = null;
                                    _loopB = null;
                                    _loopEnabled = false;
                                    _loopRemaining = -1;
                                  });
                                  _debouncedSave();
                                },
                                child: const Text('루프 해제'),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Markers
                          Row(
                            children: [
                              FilledButton.icon(
                                onPressed: _addMarker,
                                icon: const Icon(Icons.add),
                                label: const Text('마커 추가 (M)'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _openMarkerSheet,
                                icon: const Icon(Icons.view_list),
                                label: const Text('마커 목록'),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      for (int i = 0; i < _markers.length; i++)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: InputChip(
                                            label: Text(
                                              '${_markers[i].label} ${_fmt(_markers[i].t)}',
                                            ),
                                            avatar: _markers[i].color == null
                                                ? null
                                                : CircleAvatar(
                                                    backgroundColor:
                                                        _markers[i].color!,
                                                    radius: 8,
                                                  ),
                                            onPressed: () => _editMarker(i),
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
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Intents ----
class _PlayFromStartOrPauseIntent extends Intent {
  const _PlayFromStartOrPauseIntent();
}

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

class _AddMarkerIntent extends Intent {
  const _AddMarkerIntent();
}

class _LoopBetweenMarkersIntent extends Intent {
  const _LoopBetweenMarkersIntent();
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

class _PitchResetIntent extends Intent {
  const _PitchResetIntent();
}

class _SpeedPresetIntent extends Intent {
  final double value;
  const _SpeedPresetIntent(this.value);
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

  @override
  Widget build(BuildContext context) {
    final label = '${(value * 100).round()}%';
    final child = Text(label);
    return selected
        ? FilledButton.tonal(onPressed: onTap, child: child)
        : OutlinedButton(onPressed: onTap, child: child);
  }
}
