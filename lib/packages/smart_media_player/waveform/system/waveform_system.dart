import 'package:flutter/material.dart';

/// 마커 모델 (혼용 제거: 포지셔널-only / 네임드-only 2종만 지원)
class WfMarker {
  final Duration time;
  final String? label;
  final Color? color;
  final bool repeat;

  const WfMarker(this.time, [this.label, this.color, this.repeat = false]);

  const WfMarker.named({
    required this.time,
    this.label,
    this.color,
    this.repeat = false,
  });
}

/// 파형 컨트롤러(플레이어-파형 상태 브리지)
class WaveformController {
  // ===== 타임라인 =====
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  // ===== 뷰포트(스크롤/줌) =====
  final ValueNotifier<double> viewStart = ValueNotifier(0.0); // 0..1
  final ValueNotifier<double> viewWidth = ValueNotifier(1.0); // 0..1

  // ===== 루프 =====
  final ValueNotifier<Duration?> loopA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> loopB = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> loopOn = ValueNotifier<bool>(false);

  // ===== 마커 & 라벨 =====
  final ValueNotifier<List<WfMarker>> markers = ValueNotifier<List<WfMarker>>(
    <WfMarker>[],
  );
  final ValueNotifier<List<String>> markerLabels = ValueNotifier<List<String>>(
    <String>[],
  );

  // ===== 선택(드래그 영역) =====
  final ValueNotifier<Duration?> selectionA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> selectionB = ValueNotifier<Duration?>(null);

  // ===== 플레이어 콜백 바인딩 =====
  void Function(Duration t)? onSeek;
  void Function()? onPause;

  // ===== DEBUG FLAGS =====
  bool debugTrackViewport = true; // 로그 트래킹 켜기
  bool debugFreezeViewport = false; // 자동 축소 차단용
  DateTime? _lastVpLogAt;

  // ==============================================================
  // == Player Bridge
  // ==============================================================

  void updateFromPlayer({
    Duration? pos,
    Duration? dur,
    Duration? time,
    Duration? total,
  }) {
    final p = pos ?? time;
    final d = dur ?? total;
    if (p != null) position.value = p;
    if (d != null) duration.value = d;
  }

  void updateFromPlayerLegacy(Duration p, [Duration? d]) {
    updateFromPlayer(pos: p, dur: d);
  }

  void setStartCue(Duration t) {}

  // ==============================================================
  // == Async-like setters
  // ==============================================================

  Future<void> setDuration(Duration d) async {
    duration.value = d;
  }

  Future<void> setPosition(Duration p) async {
    position.value = p;
  }

  // --------------------------------------------------------------
  //  🔎 setViewport() 추적 버전
  // --------------------------------------------------------------
  Future<void> setViewport({
    required double start,
    required double width,
    String? reason,
    bool user = false,
  }) async {
    final oldStart = viewStart.value;
    final oldWidth = viewWidth.value;
    final ns = start.clamp(0.0, 1.0);
    final nw = width.clamp(0.02, 1.0);

    // freeze일 때 자동 호출 차단
    if (debugFreezeViewport && !user) {
      _vpLog(
        '[BLOCKED] reason=${reason ?? 'unknown'} user=$user '
        'old=($oldStart, $oldWidth) new=($ns, $nw) caller=${_callerFrame()}',
      );
      return;
    }

    viewStart.value = ns;
    viewWidth.value = nw;

    if (debugTrackViewport && (ns != oldStart || nw != oldWidth)) {
      final shrink = nw < oldWidth;
      _vpLog(
        '[SET] reason=${reason ?? 'unknown'} user=$user '
        'old=($oldStart, $oldWidth) → new=($ns, $nw) ${shrink ? '⚠️ SHRINK' : ''} '
        'caller=${_callerFrame()}',
      );
    }
  }

  // --------------------------------------------------------------
  //  Helpers
  // --------------------------------------------------------------
  void _vpLog(String msg) {
    final now = DateTime.now();
    if (_lastVpLogAt != null &&
        now.difference(_lastVpLogAt!).inMilliseconds < 30) {
      return;
    }
    _lastVpLogAt = now;
    // print를 사용해야 flutter 콘솔에서 필터링 없이 나옴
    print('[VIEWPORT] $msg');
  }

  String _callerFrame() {
    final st = StackTrace.current.toString().split('\n');
    for (final line in st) {
      if (line.contains('WaveformController.setViewport')) continue;
      if (line.contains('waveform_system.dart')) continue;
      if (line.contains('/lib/')) return line.trim();
    }
    return st.length > 1 ? st[1].trim() : 'unknown';
  }

  // ==============================================================
  // == 루프 & 마커 등 기존 세터 유지
  // ==============================================================

  Future<void> setLoop({Duration? a, Duration? b, bool? on}) async {
    loopA.value = a ?? loopA.value;
    loopB.value = b ?? loopB.value;
    if (on != null) loopOn.value = on;
  }

  Future<void> clearLoop() => setLoop(a: null, b: null, on: false);

  Future<void> setMarkers(List<WfMarker> list) async {
    markers.value = List<WfMarker>.from(list);
    markerLabels.value = list.map((m) => m.label ?? '').toList(growable: false);
  }

  Future<void> addMarker(WfMarker m) async {
    final list = List<WfMarker>.from(markers.value)..add(m);
    await setMarkers(list);
  }

  Future<void> clearMarkers() => setMarkers(<WfMarker>[]);

  Future<void> setSelection({Duration? a, Duration? b}) async {
    if (a != null) selectionA.value = a;
    if (b != null) selectionB.value = b;
  }

  Future<void> clearSelection() async {
    selectionA.value = null;
    selectionB.value = null;
  }
}
