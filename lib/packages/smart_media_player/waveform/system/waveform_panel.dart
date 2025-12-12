// lib/packages/smart_media_player/waveform/system/waveform_panel.dart
// v3.31.7-hotfix | 말풍선 밴드=마커 전용 / 시킹·구간선택 배제 + 높이 100
// - 상단 _markerBandPx(28px): 마커만 픽업/드래그, 클릭 시킹 무시
// - 그 외 영역: 클릭=즉시 시킹+loopOff, 드래그=구간선택(loopOn)
// - 핸들 드래그 A/B 이동, 더블탭 A/B 해제
// - AnimatedBuilder로 외부 상태 변경 즉시 반영
//
// v3.8-FF STEP 7 정렬:
// - SoundTouchAudioChain / AudioChain 의존성 제거
// - WaveformController.duration / position (FFmpeg SoT)만 사용
// - withOpacity → withValues(alpha: ...) 교체
//
// P2/P3 정렬 (StartCue / Loop / Space / FR 규칙):
// - WaveformPanel은 "타임라인 제스처 전용" 레이어로 동작
// - StartCue는 여기서 절대 수정하지 않고, Screen/Engine에서만 관리
// - Loop(A/B)는 draw/선택·설정만 담당, seek/marker 이동을 클램프하지 않음
//   (FF/FR/파형 드래그/마커 점프 = 항상 자유 시킹; Loop/StartCue는 단지 값)

import 'dart:async';
import 'package:flutter/material.dart';
import '../waveform_cache.dart';
import '../waveform_view.dart';
import 'waveform_system.dart';
import '../../ui/smp_waveform_gestures.dart'; // 🔹 드래그 StartCue 규칙 연동용

class WaveformPanel extends StatefulWidget {
  final WaveformController controller;
  final String mediaPath;
  final String mediaHash;
  final String cacheDir;
  final VoidCallback? onStateDirty;

  /// 🔹 P3: 타임라인 드래그(스크럽) 규칙 연동용 제스처 헬퍼 (옵션)
  final SmpWaveformGestures? gestures;

  const WaveformPanel({
    super.key,
    required this.controller,
    required this.mediaPath,
    required this.mediaHash,
    required this.cacheDir,
    this.onStateDirty,
    this.gestures,
  });

  @override
  State<WaveformPanel> createState() => _WaveformPanelState();
}

class _WaveformPanelState extends State<WaveformPanel> {
  // --- hit params & layout ---
  static const double _handleHitPx = 10; // A/B 핸들 판정 반경
  static const double _markerHitPx = 22; // 말풍선 근처 X 허용치
  static const double _markerBandPx = 28; // 상단 말풍선 전용 밴드 높이
  static const double _viewHeight = 100; // 파형 높이

  double _progress = 0.0;

  List<double> _rmsL = const [];

  // 드래그 상태 (루프/마커/구간 선택)
  bool _draggingA = false;
  bool _draggingB = false;
  bool _dragSelecting = false;
  int _draggingMarkerIndex = -1;

  // 🔹 상단 마커 밴드 탭 vs 드래그 구분용
  int? _markerJumpIndexCandidate;
  Offset? _markerJumpDownLocal;
  bool _markerJumpMoved = false;

  // 🔹 타임라인 스크럽 드래그 상태 (StartCue 규칙 연동용)
  int? _scrubPointerId;
  Offset? _scrubStartLocal;
  bool _scrubStarted = false;

  SmpWaveformGestures? get _gestures => widget.gestures;

  void _requestLoopUpdate(Duration? a, Duration? b) {
    final cb = widget.controller.onLoopSet;
    if (cb != null) {
      scheduleMicrotask(() => cb(a, b));
    }
  }

  void _resetMarkerJumpState() {
    _markerJumpIndexCandidate = null;
    _markerJumpDownLocal = null;
    _markerJumpMoved = false;
  }

  void _requestStartCueUpdate(Duration t) {
    final cb = widget.controller.onStartCueSet;
    if (cb != null) {
      scheduleMicrotask(() => cb(t));
    }
  }

  Listenable get _mergedListenable => Listenable.merge([
    // 🔥 StartCue는 setStartCue()에서 notifyListeners()만 호출하므로
    // 컨트롤러 자체를 리슨해서 반영하도록 추가
    widget.controller,
    widget.controller.selectionA,
    widget.controller.selectionB,
    widget.controller.loopOn,
    widget.controller.position,
    widget.controller.duration,
    widget.controller.viewStart,
    widget.controller.viewWidth,
    widget.controller.markers,
    // ⛔ startCue는 Duration 값이라 Listenable이 아님 → 제외
  ]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  void _ensureLoaded() async {
    await _load();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load() async {
    setState(() => _progress = 0.03);

    // 기본 fallback 길이 (5분) — 파일에서 읽기 전 안전값
    Duration durHint = widget.controller.duration.value > Duration.zero
        ? widget.controller.duration.value
        : const Duration(minutes: 5);

    // WaveformCache가 실제 duration을 반환한다면 그 정보만 사용
    final res = await WaveformCache.instance.loadOrBuildStereoVectors(
      mediaPath: widget.mediaPath,
      cacheDir: widget.cacheDir,
      cacheKey: widget.mediaHash,
      durationHint: durHint,
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _progress = p.clamp(0.0, 1.0));
      },
    );

    if (!mounted) return;

    // duration은 EngineApi / WaveformController.updateFromPlayer()가 관리
    // 이 Panel은 시각화용 RMS 벡터만 보유
    setState(() {
      _rmsL = res.rmsL;
      _progress = 1.0;
    });
  }

  // === 좌표 <-> 시간 변환 ===
  Duration _dxToTime(Offset localPos, Size size) {
    final c = widget.controller;
    final durMs = c.duration.value.inMilliseconds;
    final width = size.width;

    // 안전장치: duration=0, width=0 시 안정적으로 0 반환
    if (width <= 0 || durMs <= 0) return Duration.zero;

    // 0~1 frac in viewport
    final f = (localPos.dx / width).clamp(0.0, 1.0);

    // viewport 안정화: viewWidth 최소폭 0.02 보정
    final vs = c.viewStart.value.clamp(0.0, 1.0);
    final vw = c.viewWidth.value.clamp(0.02, 1.0);

    // global position fraction
    final g = (vs + f * vw).clamp(0.0, 1.0);

    return Duration(milliseconds: (g * durMs).round());
  }

  double _timeToDx(Duration t, Size size) {
    final c = widget.controller;
    final width = size.width;
    final durMs = c.duration.value.inMilliseconds;

    if (width <= 0 || durMs <= 0) return 0.0;

    final f = (t.inMilliseconds / durMs).clamp(0.0, 1.0);

    // viewport 안정화
    final vs = c.viewStart.value.clamp(0.0, 1.0);
    final vw = c.viewWidth.value.clamp(0.02, 1.0);

    final v = ((f - vs) / vw).clamp(0.0, 1.0);

    return (v * width).clamp(0.0, width);
  }

  bool _near(double x, double targetX, double tol) =>
      (x - targetX).abs() <= tol;

  // ===== 마커 컬러 규칙 (패널과 동일) =====

  static const List<String> _songFormLabels = [
    'Intro',
    'Verse',
    'Pre-Chorus',
    'Chorus',
    'Bridge',
    'Instrumental',
    'Solo',
    'Outro',
  ];

  static const Map<String, Color> _songFormColors = {
    'Intro': Colors.teal,
    'Verse': Colors.blue,
    'Pre-Chorus': Colors.indigo,
    'Chorus': Colors.red,
    'Bridge': Colors.orange,
    'Instrumental': Colors.green,
    'Solo': Colors.purple,
    'Outro': Colors.brown,
  };

  static const Color _customTextColor = Colors.deepPurple;

  bool _isAutoLetterLabel(String? label) {
    if (label == null) return false;
    final trimmed = label.trim();
    if (trimmed.length != 1) return false;
    final code = trimmed.codeUnitAt(0);
    return code >= 65 && code <= 90; // 'A'..'Z'
  }

  String? _matchSongFormLabel(String? label) {
    if (label == null) return null;
    final l = label.trim().toLowerCase();
    for (final preset in _songFormLabels) {
      if (preset.toLowerCase() == l) return preset;
    }
    return null;
  }

  Color _baseColorForMarker(int index, WfMarker m) {
    // 1) WfMarker.color가 직접 지정된 경우 우선
    if (m.color != null) return m.color!;

    final label = m.label;
    final matchedSongForm = _matchSongFormLabel(label);

    // 2) Song Form → 고정 컬러
    if (matchedSongForm != null) {
      return _songFormColors[matchedSongForm] ?? Colors.blueGrey;
    }

        // 3) 자동 A,B,C... → "문자" 기준 프리셋 (패널과 동일 규칙)
    const presets = [Colors.red, Colors.blue, Colors.amber, Colors.green];

    if (_isAutoLetterLabel(label)) {
      if (presets.isEmpty) return Colors.red;
      final trimmed = label!.trim();
      final code = trimmed.codeUnitAt(0); // 'A'..'Z'
      final letterIndex = (code - 65); // 'A' = 0
      final mapped = letterIndex >= 0 ? letterIndex % presets.length : 0;
      return presets[mapped];
    }


    // 4) 일반 텍스트 라벨 → 통일 컬러
    if (label != null && label.trim().isNotEmpty) {
      return _customTextColor;
    }

    // 5) 라벨 없음 → 프리셋
    if (presets.isEmpty) return Colors.red;
    return presets[index % presets.length];
  }


  // === 마커 히트 테스트: "상단 말풍선 밴드"에서만 픽업 ===
  int _hitMarkerIndex(Offset local, Size size) {
    if (local.dy > _markerBandPx) return -1; // 밴드 밖이면 픽업 금지
    final markers = widget.controller.markers.value;
    if (markers.isEmpty) return -1;

    int bestIdx = -1;
    double bestDx = double.infinity;
    for (int i = 0; i < markers.length; i++) {
      final mx = _timeToDx(markers[i].time, size);
      final dist = (local.dx - mx).abs();
      if (dist < bestDx) {
        bestDx = dist;
        bestIdx = i;
      }
    }
    return (bestDx <= _markerHitPx) ? bestIdx : -1;
  }

  void _setA(Duration t) {
    final c = widget.controller;

    // duration 범위 안으로만 clamp
    final durMs = c.duration.value.inMilliseconds;
    if (durMs > 0) {
      final ms = t.inMilliseconds.clamp(0, durMs);
      t = Duration(milliseconds: ms);
    }

    // ① selectionA/B 업데이트
    c.selectionA.value = t;

    if (c.selectionB.value != null && c.selectionB.value! < t) {
      final b = c.selectionB.value!;
      c.selectionB.value = t;
      c.selectionA.value = b;
    }

    // ② selection 기반 루프 "요청"만 올리기 (실제 setLoop는 Screen에서)
    final aa = c.selectionA.value;
    final bb = c.selectionB.value;
    if (aa != null && bb != null) {
      // 루프 범위 전달
      _requestLoopUpdate(aa, bb);
      // R2/R3: A가 항상 StartCue
      _requestStartCueUpdate(aa);
    }

    widget.onStateDirty?.call();
  }

  void _setB(Duration t) {
    final c = widget.controller;

    // duration 범위 안으로만 clamp
    final durMs = c.duration.value.inMilliseconds;
    if (durMs > 0) {
      final ms = t.inMilliseconds.clamp(0, durMs);
      t = Duration(milliseconds: ms);
    }

    // ① selectionB 업데이트
    c.selectionB.value = t;
    if (c.selectionA.value != null && c.selectionA.value! > t) {
      final a = c.selectionA.value!;
      c.selectionA.value = t;
      c.selectionB.value = a;
    }

    // ② selection 기반 루프 "요청"만 올리기
    final aa = c.selectionA.value;
    final bb = c.selectionB.value;
    if (aa != null && bb != null) {
      _requestLoopUpdate(aa, bb);
      // StartCue는 항상 A라서, B 바꿀 때는 굳이 다시 안 건드려도 됨
    }

    widget.onStateDirty?.call();
  }

  // selection만 지우는 헬퍼 (엔진/LoopExecutor에는 영향 없음)
  void _clearSelectionOnly() {
    final c = widget.controller;
    c.selectionA.value = null;
    c.selectionB.value = null;
  }

  void _loopOff() {
    // 루프 범위/선택 강조만 지우고,
    // 실제 loopA/B/loopOn reset은 Screen이 결정
    _clearSelectionOnly();
    _requestLoopUpdate(null, null);
    widget.onStateDirty?.call();
  }

  void _clearAB() {
    // 더블탭 = 루프 완전 해제 요청
    _loopOff();
  }

  void _updateMarkerTime(int index, Duration t) {
    final c = widget.controller;
    final list = List<WfMarker>.from(c.markers.value);
    if (index < 0 || index >= list.length) return;

    final m = list[index];
    list[index] = WfMarker.named(
      time: t,
      label: m.label,
      color: m.color,
      repeat: m.repeat,
    );

    // ❌ 정렬 때문에 드래그 인덱스가 꼬여서
    // 다른 마커가 같이 딸려오는 문제가 생겼었음.
    // list.sort((a, b) => a.time.compareTo(b.time));

    // 👉 드래그 동안에는 "현재 인덱스 그대로 유지"하는 게 중요하니까
    // 여기서는 순서 유지하고, 시간 기반 정렬/라벨 재정리는 상위(Screen)에서 담당.

    c.setMarkers(list);

    final onChanged = c.onMarkersChanged;
    if (onChanged != null) {
      scheduleMicrotask(() => onChanged(List<WfMarker>.unmodifiable(list)));
    }

    widget.onStateDirty?.call();
  }

  // 스크럽 드래그 상태 초기화
  void _resetScrubState() {
    _scrubPointerId = null;
    _scrubStartLocal = null;
    _scrubStarted = false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _mergedListenable,
      builder: (context, _) {
        final c = widget.controller;

        return LayoutBuilder(
          builder: (ctx, box) {
            final ready = _rmsL.isNotEmpty;
            if (!ready) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: (_progress > 0 && _progress <= 1.0)
                        ? _progress
                        : null,
                    minHeight: 2,
                  ),
                  const SizedBox(height: 12),
                  const Center(child: Text('파형 로딩 중…')),
                ],
              );
            }

            final vs = c.viewStart.value.clamp(0.0, 1.0);
            final vw = c.viewWidth.value.clamp(0.02, 1.0);
            final Size viewSize = Size(box.maxWidth, _viewHeight);

            // ✅ 실제 루프 표시용 시간: loopA/B 우선, 없으면 selectionA/B 사용
            final Duration? loopA = c.loopA.value ?? c.selectionA.value;
            final Duration? loopB = c.loopB.value ?? c.selectionB.value;
            final bool loopActive =
                c.loopOn.value &&
                loopA != null &&
                loopB != null &&
                loopA < loopB;

                        // ✅ Marker 색상: Song Form / 자동 A,B,C / 텍스트 직접입력 규칙 반영
            final markerList = c.markers.value;
            final List<Color?> markerColors = List<Color?>.generate(
              markerList.length,
              (i) {
                final base = _baseColorForMarker(i, markerList[i]);
                return base.withValues(alpha: 0.85);
              },
            );


            return Stack(
              children: [
                // === ① 드래그 / 핸들 / 마커 / 루프 선택 전용 ===
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) {
                    final dx = d.localPosition.dx;
                    final dy = d.localPosition.dy;

                    _draggingA = _draggingB = _dragSelecting = false;
                    _draggingMarkerIndex = -1;

                    // 핸들 히트
                    final a = c.selectionA.value;
                    final b = c.selectionB.value;
                    if (a != null) {
                      final ax = _timeToDx(a, viewSize);
                      if (_near(dx, ax, _handleHitPx)) _draggingA = true;
                    }
                    if (!_draggingA && b != null) {
                      final bx = _timeToDx(b, viewSize);
                      if (_near(dx, bx, _handleHitPx)) _draggingB = true;
                    }

                    // ⬇ 상단 말풍선 밴드에서만 마커 드래그 활성
                    if (!_draggingA && !_draggingB) {
                      final hit = _hitMarkerIndex(d.localPosition, viewSize);
                      if (hit >= 0) _draggingMarkerIndex = hit;
                    }

                    // ⬇ 구간선택은 상단 밴드 금지 (마커 전용), 나머지에서만 시작
                    if (dy > _markerBandPx &&
                        !_draggingA &&
                        !_draggingB &&
                        _draggingMarkerIndex < 0) {
                      _dragSelecting = true;
                      final t = _dxToTime(d.localPosition, viewSize);

                      // A=B=t 고정 (초기 프레임 튐 제거)
                      c.selectionA.value = t;
                      c.selectionB.value = t;

                      // loopOn 여부는 Screen이 결정
                      widget.onStateDirty?.call();
                    }

                    setState(() {});
                  },
                                    onPanUpdate: (d) {
                    final t = _dxToTime(d.localPosition, viewSize);
                    if (_draggingA) {
                      _setA(t);
                    } else if (_draggingB) {
                      _setB(t);
                    } else if (_dragSelecting) {
                      // 드래그 중에는 selectionB만 업데이트, loopA/B는 종료 시 확정
                      c.selectionB.value = t;
                      widget.onStateDirty?.call();
                    } else if (_draggingMarkerIndex >= 0) {
                      // 마커 이동: "처음 집은 마커"만 끝까지 이동시키기
                      //
                      // 교차 지점에서 다른 마커로 스위칭되는 UX를 막기 위해
                      // 드래그 시작 시 결정된 _draggingMarkerIndex만 사용한다.
                      final idx = _draggingMarkerIndex;
                      if (idx >= 0) {
                        _updateMarkerTime(idx, t);
                      }
                    }



                    setState(() {});
                  },

                  onPanEnd: (_) {
                    final a = c.selectionA.value, b = c.selectionB.value;
                    if (_dragSelecting && a != null && b != null) {
                      final aa = a <= b ? a : b;
                      final bb = a <= b ? b : a;

                      // 선택된 구간은 selectionA/B에 이미 반영돼 있음
                      // 여기서는 "이 범위로 루프 잡아줘 + StartCue는 A로" 신호만 보냄
                      _requestLoopUpdate(aa, bb);
                      _requestStartCueUpdate(aa);
                    }
                    _draggingA = _draggingB = _dragSelecting = false;
                    _draggingMarkerIndex = -1;
                    widget.onStateDirty?.call();
                    setState(() {});
                  },
                  onDoubleTap: () {
                    _clearAB();
                    setState(() {});
                  },
                  child: SizedBox(
                    height: _viewHeight,
                    width: double.infinity,
                    child: WaveformView(
                      peaks: _rmsL,
                      peaksRight: null,
                      duration: c.duration.value,
                      position: c.position.value,

                      // ✅ 실제 루프 시각화: loopA/B + loopActive
                      loopA: loopA,
                      loopB: loopB,
                      loopOn: loopActive,

                      viewStart: vs,
                      viewWidth: vw,
                      drawMode: WaveDrawMode.path,
                      dualLayer: true,
                      useSignedAmplitude: false,
                      splitStereoQuadrants: false,

                      markers: markerList.map((m) => m.time).toList(),
                      markerLabels: markerList
                          .map((m) => m.label ?? '')
                          .toList(),
                      markerColors: markerColors,

                      // ✅ StartCue는 Controller 단일 소스 (Screen에서만 설정)
                      startCue: widget.controller.startCue,
                      showStartCue: true,
                      showHandles: true,
                    ),
                  ),
                ),

                // === ② 클릭/스크럽 전용, 드래그와 경쟁 방지 ===
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      final local = event.localPosition;

                      // -----------------------------------------------
                      // ① Marker Band(상단 말풍선 영역)
                      //    - 여기서는 "점프 후보만 기억"
                      //    - 실제 점프 여부는 onPointerUp에서
                      //      이동량이 거의 없을 때(=탭)만 결정
                      //    - 드래그로 판단되면 점프하지 않고 순수 편집
                      // -----------------------------------------------
                      if (local.dy <= _markerBandPx) {
                        final hit = _hitMarkerIndex(local, viewSize);
                        if (hit >= 0) {
                          _markerJumpIndexCandidate = hit;
                          _markerJumpDownLocal = local;
                          _markerJumpMoved = false;
                        } else {
                          _resetMarkerJumpState();
                        }

                        // 상단 밴드에서는 scrubbing 사용 안 함
                        _resetScrubState();
                        return;
                      }

                      // -----------------------------------------------
                      // ② 일반 클릭 시킹 (anywhere else)
                      //    - LoopOn 여부와 무관하게 순수 seek
                      //    - StartCue/Loop는 Screen/Engine에서만 관리
                      // -----------------------------------------------
                      final t = _dxToTime(local, viewSize);
                      final controller = widget.controller;

                      // 재생 위치 즉시 반영 (SoT는 EngineApi가 최종 소스)
                      controller.position.value = t;

                      // ✅ 클릭 = "여기를 StartCue로 쓰고 싶다" + "기존 루프는 버리고 새 상태 시작"
                      _clearSelectionOnly();
                      _requestLoopUpdate(null, null); // 루프 해제 요청
                      _requestStartCueUpdate(t); // StartCue = 클릭 지점

                      final cb = controller.onSeek;
                      if (cb != null) {
                        // 이 클릭은 순수 시킹 + StartCue 재설정
                        scheduleMicrotask(() => cb(t));
                      }

                      // 🔹 스크럽용 포인터 상태 초기화
                      _scrubPointerId = event.pointer;
                      _scrubStartLocal = local;
                      _scrubStarted = false;

                      setState(() {});
                    },
                    onPointerMove: (event) {
                      final local = event.localPosition;

                      // 🔹 상단 마커 밴드에서는 scrubbing 하지 않음
                      if (local.dy <= _markerBandPx) {
                        // 탭 vs 드래그 구분을 위한 이동량 체크
                        if (_markerJumpIndexCandidate != null &&
                            _markerJumpDownLocal != null) {
                          final dx = (local.dx - _markerJumpDownLocal!.dx)
                              .abs();
                          final dy = (local.dy - _markerJumpDownLocal!.dy)
                              .abs();
                          const double kMarkerDragThreshold = 3.0;
                          if (dx >= kMarkerDragThreshold ||
                              dy >= kMarkerDragThreshold) {
                            // 일정 이상 움직였으면 "드래그"로 판정 → 점프 금지
                            _markerJumpMoved = true;
                          }
                        }
                        return;
                      }

                      // ==== 아래부터는 scrubbing 로직 ====
                      // 스크럽 대상 포인터가 아니면 무시
                      if (_scrubPointerId == null ||
                          event.pointer != _scrubPointerId) {
                        return;
                      }

                      // 버튼이 떼어진 상태면 무시
                      if (!event.down) return;

                      // 🔹 아직 스크럽 시작 안 했으면, 슬롭(threshold) 체크
                      if (!_scrubStarted && _scrubStartLocal != null) {
                        final dx = (local.dx - _scrubStartLocal!.dx)
                            .abs()
                            .toDouble();
                        final dy = (local.dy - _scrubStartLocal!.dy)
                            .abs()
                            .toDouble();

                        // 너무 작은 이동은 "클릭"으로 취급
                        const double kScrubThreshold = 3.0;
                        if (dx < kScrubThreshold && dy < kScrubThreshold) {
                          return;
                        }

                        // threshold를 넘겼으므로, 이제부터 "스크럽 드래그" 시작
                        _scrubStarted = true;

                        // 🔥 드래그 앵커 = 포인터 다운 시점의 시간
                        final anchorLocal = _scrubStartLocal!;
                        final anchorTime = _dxToTime(anchorLocal, viewSize);
                        _gestures?.onDragStart(anchor: anchorTime);
                      }

                      if (!_scrubStarted) return;

                      final controller = widget.controller;
                      final t = _dxToTime(local, viewSize);

                      // UI 위치 업데이트
                      controller.position.value = t;

                      final cb = controller.onSeek;
                      if (cb != null) {
                        // 🔥 드래그 동안 연속 시킹
                        scheduleMicrotask(() => cb(t));
                      }

                      setState(() {});
                    },
                    onPointerUp: (event) {
                      final local = event.localPosition;

                      // 🔹 상단 마커 밴드에서 손 뗀 경우
                      if (local.dy <= _markerBandPx) {
                        // 이동이 거의 없었다면 = "탭" → 점프
                        if (_markerJumpIndexCandidate != null &&
                            !_markerJumpMoved) {
                          final idx = _markerJumpIndexCandidate!;
                          final controller = widget.controller;
                          final markers = controller.markers.value;
                          if (idx >= 0 && idx < markers.length) {
                            final jump = markers[idx].time;
                            controller.position.value = jump;
                            final cb = controller.onSeek;
                            if (cb != null) {
                              scheduleMicrotask(() => cb(jump));
                            }
                          }
                        }
                        _resetMarkerJumpState();
                        _resetScrubState();
                        return;
                      }

                      // ==== scrubbing 종료 로직 ====
                      if (_scrubPointerId != null &&
                          event.pointer == _scrubPointerId) {
                        if (_scrubStarted) {
                          // 🔥 드래그가 실제로 있었던 경우에만 dragEnd 호출
                          _gestures?.onDragEnd();
                        }
                        _resetScrubState();
                      }
                    },
                    onPointerCancel: (event) {
                      _resetMarkerJumpState();

                      if (_scrubPointerId != null &&
                          event.pointer == _scrubPointerId) {
                        if (_scrubStarted) {
                          _gestures?.onDragEnd();
                        }
                        _resetScrubState();
                      }
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
