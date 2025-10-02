// lib/packages/smart_media_player/smart_media_player_screen.dart
// v1.85.1 | Waveform 디그레이드 캐시(결정론) + 단축키 오타 수정(keyS)
// - v1.85 기능/UX 유지, just_waveform API 불일치 이슈 임시 우회
// - 추후 v1.85.2에서 실제 추출 로직로 교체 예정

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

  // UI 상태
  double _speed = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // AB 루프
  Duration? _loopA;
  Duration? _loopB;
  bool _loopEnabled = false;

  // 자동 저장 디바운스
  Timer? _saveDebounce;

  // 파형 데이터(0..1)
  List<double> _peaks = const [];
  double _waveProgress = 0; // 0..1

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

    _posSub = _player.positionStream.listen((pos) async {
      if (!mounted) return;
      setState(() => _position = pos);

      if (_loopEnabled && _loopA != null && _loopB != null) {
        final a = _loopA!;
        final b = _loopB!;
        if (pos >= b) {
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
      setState(() => _waveProgress = 0.1);
      // 🔧 임시: 결정론 가짜 파형(캐시 파일로 저장/로드는 동일 키 기반)
      final peaks = await WaveformCache.instance.loadOrBuildDegraded(
        cacheDir: _cacheDir,
        cacheKey: widget.mediaHash,
        bars: 800,
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
      ).showSnackBar(SnackBar(content: Text('파형 준비 실패(임시 모드): $e')));
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
        setState(() {
          _loopA = a > 0 ? Duration(milliseconds: a) : null;
          _loopB = b > 0 ? Duration(milliseconds: b) : null;
          _loopEnabled = (m['loopOn'] ?? false) == true;
          _speed = sp.clamp(0.5, 1.5);
        });

        _normalizeLoopOrder();

        await _player.setSpeed(_speed);
        if (posMs > 0) {
          final d = Duration(milliseconds: posMs);
          if (_duration == Duration.zero) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              if (_player.duration != null && d < _player.duration!) {
                await _player.seek(d);
              }
            });
          } else if (d < _duration) {
            await _player.seek(d);
          }
        }
      }
    } catch (_) {
      /* ignore */
    }
  }

  void _normalizeLoopOrder() {
    if (_loopA != null &&
        _loopB != null &&
        !_loopA!.isNegative &&
        !_loopB!.isNegative) {
      if (_loopA! >= _loopB!) {
        final two = const Duration(seconds: 2);
        final trackDur = _duration == Duration.zero ? null : _duration;
        final newB = trackDur != null
            ? ((_loopA! + two) < trackDur
                  ? _loopA! + two
                  : (trackDur - const Duration(milliseconds: 1)))
            : _loopA;
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
      'version': 'v1.85.1',
      'markers': <Map<String, dynamic>>[],
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
      const Duration(milliseconds: 1500),
      () => _saveSidecar(toast: false),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    unawaited(_saveSidecar(toast: false));
    _posSub?.cancel();
    _stateSub?.cancel();
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
    if (_duration > Duration.zero && target > _duration) target = _duration;
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
          message: '사이드카 저장 (S)',
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
        LogicalKeySet(LogicalKeyboardKey.keyS): const _SaveIntent(), // ✅ 오타 수정
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
                        (_duration.inMilliseconds > 0
                                ? _duration.inMilliseconds
                                : 1)
                            .toDouble(),
                    onChanged: (v) async {
                      final d = Duration(milliseconds: v.toInt());
                      await _player.seek(d);
                    },
                  ),

                  const SizedBox(height: 8),

                  // Transport
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
                    ],
                  ),

                  const Divider(height: 24),

                  // Waveform section
                  SizedBox(
                    height: 96,
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
                            onSeek: (d) async => _player.seek(d),
                          ),
                  ),

                  const SizedBox(height: 16),

                  // A/B loop
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
                              ? 'A 지점 설정 (A)'
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
                              ? 'B 지점 설정 (B)'
                              : 'B 재설정 (${_fmt(_loopB!)})',
                        ),
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
