// lib/packages/smart_media_player/waveform/system/waveform_panel.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../waveform_tuning.dart';
import '../waveform_cache.dart';
import '../waveform_view.dart';
import 'waveform_system.dart';

/// SmartMediaPlayer에 의존하지 않는 “독립 파형 모듈”
/// - 캐시 빌드(loadOrBuildStereoSigned)
/// - WaveformView 그리기
/// - 컨트롤러(WaveformController)와 양방향 바인딩

 
class WaveformPanel extends StatefulWidget {
  final WaveformController controller;

  /// 미디어 식별
  final String mediaPath;
  final String mediaHash;
  final String cacheDir;

  /// 외부 저장/동기화 트리거를 위해 호출자가 받을 수 있는 훅(선택)
  final VoidCallback? onStateDirty; // 사이드카/메모 등 저장 디바운스 트리거

  /// 시각 모드 고정(Transcribe-like 등)
  final bool visualExact;
  final bool useSignedAmplitude;
  final bool splitStereoQuadrants;

  const WaveformPanel({
    super.key,
    required this.controller,
    required this.mediaPath,
    required this.mediaHash,
    required this.cacheDir,
    this.onStateDirty,
    this.visualExact = true,
    this.useSignedAmplitude = true,
    this.splitStereoQuadrants = true,
  });

  @override
  State<WaveformPanel> createState() => _WaveformPanelState();
}

class _WaveformPanelState extends State<WaveformPanel> {
  List<double> _l = [];
  List<double> _r = [];
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _buildWaveform();
  }

  @override
  void didUpdateWidget(covariant WaveformPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 다른 파일로 바뀌면 재생성
    if (oldWidget.mediaPath != widget.mediaPath ||
        oldWidget.mediaHash != widget.mediaHash ||
        oldWidget.cacheDir != widget.cacheDir) {
      _buildWaveform();
    }
  }

  Future<void> _buildWaveform() async {
    setState(() {
      _l = [];
      _r = [];
      _progress = 0.02;
    });

    final durHint = widget.controller.duration.value;

    try {
      final (lSigned, rSigned) = await WaveformCache.instance
          .loadOrBuildStereoSigned(
            mediaPath: widget.mediaPath,
            cacheDir: widget.cacheDir,
            cacheKey: widget.mediaHash,
            durationHint: durHint,
            onProgress: (p) {
              if (!mounted) return;
              final v = p.isNaN ? 0.0 : p.clamp(0.0, 1.0);
              setState(() => _progress = v);
            },
          );

      if (!mounted) return;
      setState(() {
        _l = lSigned;
        _r = rSigned;
        _progress = 1.0;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파형 생성 실패: $e')));
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    // 컨트롤러의 값들을 즉시 읽어 위젯으로 전달
    return AnimatedBuilder(
      animation: Listenable.merge([
        c.duration,
        c.position,
        c.viewStart,
        c.viewWidth,
        c.loopA,
        c.loopB,
        c.loopOn,
        c.startCue,
        c.selA,
        c.selB,
        c.markers,
      ]),
      builder: (ctx, _) {
        final duration = c.duration.value;
        final position = c.position.value;
        final loopA = c.loopA.value;
        final loopB = c.loopB.value;
        final loopOn = c.loopOn.value;
        final startCue = c.startCue.value;
        final viewStart = c.viewStart.value;
        final viewWidth = c.viewWidth.value;

        final markers = c.markers.value;
        final markerDurations = markers.map((e) => e.t).toList();
        final markerLabels = markers.map((e) => e.label).toList();
        final markerColors = markers.map((e) => e.color).toList();

        final ready = _l.isNotEmpty && _r.isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 헤더(파일명/프로그레스)
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.basename(widget.mediaPath),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_progress < 1.0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('파형 ${(_progress * 100).toStringAsFixed(0)}%'),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            SizedBox(
              height: WaveformTuning.panelHeight, // e.g. 100~130
              child: !ready
                  ? Row(
                      children: [
                        const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '파형 준비 중… ${(_progress * 100).toStringAsFixed(0)}%',
                        ),
                      ],
                    )
                  : ClipRect(
                      // 오버플로 경고 방지
                      child: WaveformView(
                        peaks: _l,
                        peaksRight: _r,
                        peaksAreNormalized: true,
                        visualExact: widget.visualExact,
                        useSignedAmplitude: widget.useSignedAmplitude,
                        splitStereoQuadrants: widget.splitStereoQuadrants,
                        drawMode: WaveDrawMode.path,
                        pathSwitchBarsPerPixel: 9999,
                        candleSwitchBarsPerPixel: 9999,

                        duration: duration,
                        position: position,
                        loopA: loopA,
                        loopB: loopB,
                        loopOn: loopOn,
                        markers: markerDurations,
                        markerLabels: markerLabels,
                        markerColors: markerColors,
                        viewStart: viewStart,
                        viewWidth: viewWidth,
                        selectionMode: true,
                        selectionA: c.selA.value,
                        selectionB: c.selB.value,
                        startCue: startCue,


                      // === 이벤트 바인딩: 컨트롤러로 되돌림 ===
                      onSeek: (d) async {
                        await widget.controller.onSeek?.call(d);
                        widget.onStateDirty?.call();
                      },
                      onStartCueChanged: (d) {
                        c.setStartCue(_clampDur(d, duration));
                        widget.onStateDirty?.call();
                      },
                      onLoopAChanged: (d) {
                        c.setLoop(a: _clampDur(d, duration));
                        widget.onStateDirty?.call();
                      },
                      onLoopBChanged: (d) {
                        c.setLoop(b: _clampDur(d, duration));
                        widget.onStateDirty?.call();
                      },
                      onRailTapToSeek: (d) async {
                        await widget.controller.onSeek?.call(d);
                      },
                      onMarkerDragStart: (_) {},
                      onMarkerDragUpdate: (i, d) {
                        final list = List<WfMarker>.from(c.markers.value);
                        if (i >= 0 && i < list.length) {
                          list[i].t = _clampDur(d, duration);
                          c.setMarkers(list);
                        }
                      },
                      onMarkerDragEnd: (_, __) => widget.onStateDirty?.call(),
                      onSelectStart: (d) => c.selA.value = d,
                      onSelectUpdate: (d) => c.selB.value = d,
                      onSelectEnd: (a, b) {
                        if (a == null || b == null) return;
                        final A = a <= b ? a : b;
                        final B = b >= a ? b : a;
                        c.setLoop(
                          a: A,
                          b: _safeLoopB(A, B, duration),
                          on: true,
                        );
                        c.selA.value = null;
                        c.selB.value = null;
                        c.setStartCue(A);
                        widget.onStateDirty?.call();
                      },
                    ),
                  ),
            ),
          ],
        );
      },
    );
  }

  Duration _clampDur(Duration v, Duration max) {
    if (v < Duration.zero) return Duration.zero;
    if (v > max && max > Duration.zero)
      return max - const Duration(milliseconds: 1);
    return v;
  }

  Duration _safeLoopB(Duration a, Duration b, Duration dur) {
    var B = b - const Duration(milliseconds: 1);
    if (B <= a) {
      B = a + const Duration(milliseconds: 500);
      if (dur > Duration.zero && B >= dur) {
        final maxAllowed = dur - const Duration(milliseconds: 1);
        if (maxAllowed <= Duration.zero) {
          B = Duration.zero;
        } else {
          B = maxAllowed;
        }
      }
    }
    return B;
  }
}
