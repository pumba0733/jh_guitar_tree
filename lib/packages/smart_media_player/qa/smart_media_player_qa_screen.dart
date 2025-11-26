import 'dart:async';
import 'package:flutter/material.dart';

// Engine / Video / Loop
import '../engine/engine_api.dart';
import '../loop/loop_executor.dart';

// QA Tools
import 'smp_engine_drift_logger.dart';
import 'smp_ffrw_tick_profiler.dart';
import 'smp_long_session_verifier.dart';
import 'smp_loop_stress_tester.dart';
import 'smp_unified_seek_tester.dart';
import 'smp_video_sync_verifier.dart';

class SmartMediaPlayerQaScreen extends StatefulWidget {
  const SmartMediaPlayerQaScreen({super.key});

  @override
  State<SmartMediaPlayerQaScreen> createState() =>
      _SmartMediaPlayerQaScreenState();
}

class _SmartMediaPlayerQaScreenState extends State<SmartMediaPlayerQaScreen> {
  final List<String> _logs = [];
  void _add(String m) {
    setState(() => _logs.insert(0, m));
  }

  // QA modules
  SmpEngineDriftLogger? _drift;
  SmpFfRwTickProfiler? _ffrw;
  SmpLongSessionVerifier? _long;
  SmpLoopStressTester? _loopTester;
  SmpUnifiedSeekTester? _seekTester;
  SmpVideoSyncVerifier? _videoTester;

  // Loop Executor (QA 전용)
  late LoopExecutor _loopExec;

  // File picker text
  String? _loadedFile;

  @override
  void initState() {
    super.initState();

    // LoopExecutor (QA 버전)
    _loopExec = LoopExecutor(
      getPosition: () => EngineApi.instance.position,
      getDuration: () => EngineApi.instance.duration,
      seek: (d) => EngineApi.instance.seekUnified(d),
      play: () => EngineApi.instance.play(),
      pause: () => EngineApi.instance.pause(),
    );
  }

  @override
  void dispose() {
    _stopAllQa();
    super.dispose();
  }

  void _stopAllQa() {
    _drift?.stop();
    _ffrw?.stop();
    _long?.stop();
    _loopTester?.stop();
    _seekTester?.stop();
    _videoTester?.stop();
  }

  Future<void> _loadFile() async {
    // === 실제 파일 선택 ===
    // macOS에서는 파일 선택이 필요하므로 간단한 텍스트 입력으로 대체
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('파일 경로 입력'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '/Users/.../test.mp3'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () async {
              final path = controller.text.trim();
              Navigator.pop(context);
              if (path.isEmpty) return;

              try {
                final dur = await EngineApi.instance.load(
                  path: path,
                  onDuration: (_) {},
                );
                setState(() {
                  _loadedFile = path;
                });
                _add('[LOAD] OK path=$path dur=$dur');
              } catch (e) {
                _add('[LOAD] ERROR: $e');
              }
            },
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Widget _buildQaButton(
    String label,
    VoidCallback onTap, {
    Color color = Colors.blue,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          minimumSize: const Size(double.infinity, 46),
        ),
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eng = EngineApi.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('SmartMediaPlayer QA')),
      body: Row(
        children: [
          // ===============================================================
          // LEFT: Controls
          // ===============================================================
          SizedBox(
            width: 340,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '① File',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton(
                    'Open File (mp3/mp4)',
                    _loadFile,
                    color: Colors.black87,
                  ),
                  if (_loadedFile != null) ...[
                    Text(
                      'Loaded: $_loadedFile',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],

                  const SizedBox(height: 28),
                  const Text(
                    '② Playback',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton('Play', () => eng.play()),
                  _buildQaButton('Pause', () => eng.pause()),
                  _buildQaButton(
                    'SpaceBehavior',
                    () => eng.spaceBehavior(const Duration(milliseconds: 0)),
                  ),

                  const SizedBox(height: 28),
                  const Text(
                    '③ Seek Test',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton('Seek +1s', () {
                    final t = eng.position + const Duration(seconds: 1);
                    eng.seekUnified(t);
                  }),
                  _buildQaButton('Seek -1s', () {
                    final t = eng.position - const Duration(seconds: 1);
                    eng.seekUnified(t);
                  }),
                  _buildQaButton('SeekTester: Start', () {
                    _seekTester ??= SmpUnifiedSeekTester(onLog: _add);
                    _seekTester!.start();
                  }),
                  _buildQaButton('SeekTester: Stop', () {
                    _seekTester?.stop();
                  }),

                  const SizedBox(height: 28),
                  const Text(
                    '④ FFRW',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton(
                    'FF ON',
                    () => eng.fastForward(true, startCue: Duration.zero),
                  ),
                  _buildQaButton(
                    'FF OFF',
                    () => eng.fastForward(false, startCue: Duration.zero),
                  ),
                  _buildQaButton(
                    'FR ON',
                    () => eng.fastReverse(true, startCue: Duration.zero),
                  ),
                  _buildQaButton(
                    'FR OFF',
                    () => eng.fastReverse(false, startCue: Duration.zero),
                  ),
                  _buildQaButton('FFRW Profiler Start', () {
                    _ffrw ??= SmpFfRwTickProfiler(onLog: _add);
                    _ffrw!.start();
                  }),
                  _buildQaButton('FFRW Profiler Stop', () => _ffrw?.stop()),

                  const SizedBox(height: 28),
                  const Text(
                    '⑤ Loop Test',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton('LoopTester Start (A=2s, B=5s)', () {
                    _loopExec.setA(const Duration(seconds: 2));
                    _loopExec.setB(const Duration(seconds: 5));
                    _loopExec.setLoopEnabled(true);

                    _loopTester ??= SmpLoopStressTester(
                      loop: _loopExec,
                      onLog: _add,
                    );
                    _loopTester!.start();
                  }),
                  _buildQaButton('LoopTester Stop', () => _loopTester?.stop()),

                  const SizedBox(height: 28),
                  const Text(
                    '⑥ Video Sync',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton('VideoSyncVerifier Start', () {
                    _videoTester ??= SmpVideoSyncVerifier(onLog: _add);
                    _videoTester!.start();
                  }),
                  _buildQaButton(
                    'VideoSyncVerifier Stop',
                    () => _videoTester?.stop(),
                  ),

                  const SizedBox(height: 28),
                  const Text(
                    '⑦ Drift / Long',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  _buildQaButton('DriftLogger Start', () {
                    _drift ??= SmpEngineDriftLogger(onLog: _add);
                    _drift!.start();
                  }),
                  _buildQaButton('DriftLogger Stop', () => _drift?.stop()),
                  _buildQaButton('LongSession Start', () {
                    _long ??= SmpLongSessionVerifier(onLog: _add);
                    _long!.start();
                  }),
                  _buildQaButton('LongSession Stop', () => _long?.stop()),

                  const SizedBox(height: 28),
                  _buildQaButton(
                    'STOP ALL',
                    _stopAllQa,
                    color: Colors.redAccent,
                  ),
                ],
              ),
            ),
          ),

          // ===============================================================
          // RIGHT: Console Logs
          // ===============================================================
          Expanded(
            child: Container(
              color: Colors.black,
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(8),
                itemCount: _logs.length,
                itemBuilder: (_, i) {
                  return Text(
                    _logs[i],
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.greenAccent,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
