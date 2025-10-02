// packages/smart_media_player/smart_media_player_screen.dart
// v1.83 MVP | 내장 스마트 미디어 플레이어
// - just_audio 기반 재생/일시정지/시킹/재생속도
// - AB 루프(선택) + 루프 on/off
// - Save → 같은 폴더에 current.gtxsc(JSON) 저장 (XscSyncService가 감시/업로드)
// - 외부에서 받은 prepared.mediaPath / prepared.sidecarPath 사용

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

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

  // 사이드카 경로
  String get _sidecarPath => p.join(widget.studentDir, 'current.gtxsc');

  @override
  void initState() {
    super.initState();
    _initAudio();
    _loadSidecarIfAny();
  }

  Future<void> _initAudio() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    await _player.setFilePath(widget.mediaPath);
    _duration = _player.duration ?? Duration.zero;

    // position listener
    _posSub = _player.positionStream.listen((pos) async {
      if (!mounted) return;
      setState(() => _position = pos);

      // AB 루프 동작
      if (_loopEnabled && _loopA != null && _loopB != null) {
        if (pos >= _loopB!) {
          await _player.seek(_loopA);
        }
      }
    });

    _stateSub = _player.playerStateStream.listen((st) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _loadSidecarIfAny() async {
    final f = File(widget.initialSidecar ?? _sidecarPath);
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map) {
        final m = Map<String, dynamic>.from(j);
        setState(() {
          final a = (m['loopA'] ?? 0).toInt();
          final b = (m['loopB'] ?? 0).toInt();
          _loopA = a > 0 ? Duration(milliseconds: a) : null;
          _loopB = b > 0 ? Duration(milliseconds: b) : null;
          _loopEnabled = (m['loopOn'] ?? false) == true;
          final sp = (m['speed'] ?? 1.0).toDouble();
          _speed = sp.clamp(0.5, 1.5);
        });
        await _player.setSpeed(_speed);
      }
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _saveSidecar() async {
    final m = {
      'studentId': widget.studentId,
      'mediaHash': widget.mediaHash,
      'speed': _speed,
      'loopA': _loopA?.inMilliseconds ?? 0,
      'loopB': _loopB?.inMilliseconds ?? 0,
      'loopOn': _loopEnabled,
      'savedAt': DateTime.now().toIso8601String(),
      'media': p.basename(widget.mediaPath),
    };
    try {
      final f = File(_sidecarPath);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(m),
        flush: true,
      );
      if (mounted) {
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

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final playing = _player.playerState.playing;
    final title = p.basename(widget.mediaPath);

    return Scaffold(
      appBar: AppBar(
        title: Text('스마트 미디어 플레이어 — $title'),
        actions: [
          IconButton(
            tooltip: '사이드카 저장(current.gtxsc)',
            onPressed: _saveSidecar,
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress
            Text('${_fmt(_position)} / ${_fmt(_duration)}'),
            Slider(
              value: _position.inMilliseconds
                  .clamp(0, _duration.inMilliseconds)
                  .toDouble(),
              min: 0,
              max: (_duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1)
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
                  onPressed: () => playing ? _player.pause() : _player.play(),
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  label: Text(playing ? '일시정지' : '재생'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _player.seek(Duration.zero),
                  icon: const Icon(Icons.replay),
                  label: const Text('처음으로'),
                ),
                const Spacer(),
                // speed
                DropdownButton<double>(
                  value: _speed,
                  items: const [
                    DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                    DropdownMenuItem(value: 0.75, child: Text('0.75x')),
                    DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                    DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                    DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _speed = v);
                    await _player.setSpeed(v);
                  },
                ),
              ],
            ),

            const Divider(height: 24),

            // A/B loop
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => setState(() => _loopA = _position),
                  child: Text(
                    _loopA == null ? 'A 지점 설정' : 'A 재설정 (${_fmt(_loopA!)})',
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => setState(() => _loopB = _position),
                  child: Text(
                    _loopB == null ? 'B 지점 설정' : 'B 재설정 (${_fmt(_loopB!)})',
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  value: _loopEnabled,
                  onChanged: (v) => setState(() => _loopEnabled = v),
                ),
                const Text('루프'),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _loopA = null;
                    _loopB = null;
                    _loopEnabled = false;
                  }),
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
    );
  }
}
