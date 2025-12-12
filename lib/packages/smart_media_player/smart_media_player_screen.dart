import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sync/lesson_memo_sync.dart';
import 'package:path/path.dart' as p;
import '../../ui/components/save_status_indicator.dart';
import '../../ui/components/app_controls.dart'; // ✅ NEW: 공통 UI (AppSection, AppMiniButton, PresetSquare)
import '../../services/lesson_service.dart';

// ===== media_kit =====
import 'ui/smp_control_panel.dart';
import 'ui/smp_transport_bar.dart';
import 'ui/smp_marker_panel.dart';
import 'ui/smp_shortcuts.dart';
import 'ui/smp_waveform_gestures.dart';
import 'ui/smp_notes_panel.dart';
import 'engine/engine_api.dart';
import 'video/sticky_video_overlay.dart';

// NEW
import 'package:guitartree/packages/smart_media_player/waveform/system/waveform_system.dart'
show WaveformController, WfMarker;

import 'waveform/system/waveform_panel.dart';
import 'waveform/waveform_tuning.dart';
import 'models/marker_point.dart';
import 'sync/sidecar_sync_db.dart';
import 'utils/debounced_saver.dart';
import 'loop/loop_executor.dart';

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

/// 루프 패턴의 한 스텝 (템포 + 반복 횟수)
class _LoopPatternStep {
final double tempo; // 0.5 ~ 1.5
final int repeats; // 1 ~ 200

const _LoopPatternStep({
required this.tempo,
required this.repeats,
});
}

// A~C 패치: WidgetsBindingObserver 믹스인 추가
class _SmartMediaPlayerScreenState extends State<SmartMediaPlayerScreen>
with WidgetsBindingObserver {
late LoopExecutor _loopExec;
late final DebouncedSaver _saver;
late SmpWaveformGestures _gestures;

// Engine position 스트림 구독 (SoT 단일 진입점)
StreamSubscription<Duration>? _positionSub;

// media_kit
Timer? _applyDebounce;
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

// AB 루프
Duration? _loopA;
Duration? _loopB;
bool _loopEnabled = false;
int _loopRepeat = 0; // 0=∞
int _loopRemaining = -1;

  // 🔁 루프 패턴 상태
  //
  // 예: [ 0.8×4회, 0.9×4회, 1.0×4회 ]
  //  - patternSteps: 전체 스텝 목록
  //  - patternActive: 현재 패턴 모드가 켜져 있는지
  //  - patternIndex: 현재 진행 중인 스텝 인덱스(0-based)
  List<_LoopPatternStep> _loopPatternSteps = [];
  bool _loopPatternActive = false;
  int _loopPatternIndex = 0;

  /// 현재 스텝에서 남은 반복 회수 (패턴 모드에서만 사용)
  int _loopPatternStepRemaining = 0;

  /// 패턴 시작 전의 기준 템포 (패턴 종료/해제 시 복구용)
  double? _loopPatternBaseSpeed;

  /// 현재 유효한 루프 구간이 있는지 여부
  bool get _hasValidLoopRange =>
      _loopA != null && _loopB != null && _loopA! < _loopB!;

  Duration get _patternStartTarget => _hasValidLoopRange ? _loopA! : _startCue;

  // --- Loop / Pattern 상태 플래그 ---------------------------------

  bool get _hasLoopRange =>
      _loopA != null && _loopB != null && _loopA! < _loopB!;

  bool get _loopOnEffective => _hasLoopRange && _loopEnabled;

  bool get _patternDefined => _loopPatternSteps.isNotEmpty;

  bool get _patternRunning =>
      _patternDefined && _loopPatternActive && _loopPatternStepRemaining > 0;

  /// Loop / Pattern / StartCue / LoopExecutor / WaveformController를
  /// 한 번에 정리하는 중앙 상태머신 엔트리.
  ///
  /// - 어떤 이벤트(패턴 On/Off, 루프 해제, StartCue 이동)가 섞여도
  ///   이 함수 끝나고 나면 상태는 항상 일관된 형태로 수렴해야 한다.
  void _reconcileLoopAndPattern(String reason) {
    final dur = _effectiveDuration;

    // 1) duration 기준으로 A/B/StartCue 먼저 클램프
    Duration? newA = _loopA;
    Duration? newB = _loopB;
    var newStartCue = _startCue;

    if (dur > Duration.zero) {
      if (newA != null) newA = _clamp(newA, Duration.zero, dur);
      if (newB != null) newB = _clamp(newB, Duration.zero, dur);
      newStartCue = _clamp(newStartCue, Duration.zero, dur);
    } else {
      if (newA != null && newA < Duration.zero) newA = Duration.zero;
      if (newB != null && newB < Duration.zero) newB = Duration.zero;
      if (newStartCue < Duration.zero) newStartCue = Duration.zero;
    }

    // 2) 루프 유효성 재판정
    bool loopValid = false;
    if (newA != null && newB != null && newA < newB) {
      loopValid = true;
    } else {
      // A/B 중 하나만 있거나, 뒤집혀 있으면 일단 루프 범위는 없는 상태로 본다.
      if (newA != null && newB != null && newA >= newB) {
        newA = null;
        newB = null;
      }
      loopValid = false;
    }

    // 3) 루프 유효성에 따라 loopEnabled 보정
    if (!loopValid) {
      _loopEnabled = false;
    }

    _loopA = newA;
    _loopB = newB;

    // 4) StartCue는 항상 루프 안에만 위치 (있다면)
    _startCue = _normalizeStartCueForLoop(newStartCue);

    // 5) LoopExecutor / WaveformController와 동기화
    if (_loopA != null && _loopB != null && _loopA! < _loopB!) {
      _loopExec.setA(_loopA!);
      _loopExec.setB(_loopB!);
      _loopExec.setLoopEnabled(_loopEnabled);

      _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    } else {
      // 루프 범위 자체가 없으면 실행기도 항상 OFF
      _loopExec.setLoopEnabled(false);
      _wf.setLoop(a: null, b: null, on: false);
    }

    _wf.setStartCue(_startCue);

    // 6) 패턴 상태와의 일관성 정리
    if (!_hasLoopRange || !_loopEnabled || !_patternDefined) {
      // 루프가 없거나, 루프가 꺼져 있거나, 패턴 정의가 없으면
      // "패턴 실행" 상태는 항상 false
      if (_loopPatternActive || _loopPatternStepRemaining > 0) {
        _loopPatternActive = false;
        _loopPatternStepRemaining = 0;
        _loopRemaining = _loopExec.remaining;
      }
    } else {
      // 루프 + 패턴 정의 + 루프 ON 이라면
      // active 플래그는 유지하되, stepRemaining이 0 이하면 현재 스텝 기준으로 세팅
      if (_loopPatternActive) {
        if (_loopPatternIndex >= _loopPatternSteps.length) {
          _loopPatternIndex = _loopPatternSteps.length - 1;
        }
        if (_loopPatternIndex < 0) _loopPatternIndex = 0;

        if (_loopPatternStepRemaining <= 0) {
          _loopPatternStepRemaining =
              _loopPatternSteps[_loopPatternIndex].repeats;
        }
        _loopRemaining = _loopPatternStepRemaining;
      }
    }

    // 7) 로그
    _logSoTScreen(
      'RECONCILE[$reason]',
      pos: _position,
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }


  /// 루프 패턴 상태를 모두 초기화하고, 필요 시 템포를 패턴 이전 상태로 되돌린다.
  ///
  /// - 이 함수는 **"패턴 전체 종료 / 정리"**용이다.
  ///   - 패턴이 끝까지 돌았을 때
  ///   - 사용자가 일반 반복 횟수를 직접 만졌을 때 등
  ///
  /// - restoreTempo: 패턴 시작 전 속도로 되돌릴지 여부
  /// - clearSteps  : true면 패턴 스텝 정의 자체를 제거
  void _resetLoopPattern({bool restoreTempo = true, bool clearSteps = false}) {
    final hadPatternState = _loopPatternActive || _loopPatternStepRemaining > 0;

    // 복구 대상 템포를 먼저 캡쳐 (setState 안/밖에서 같이 쓸 수 있게)
    final baseSpeed = restoreTempo && _loopPatternBaseSpeed != null
        ? _loopPatternBaseSpeed!.clamp(0.5, 1.5)
        : null;

    setState(() {
      _loopPatternActive = false;
      _loopPatternIndex = 0;
      _loopPatternStepRemaining = 0;

      if (clearSteps) {
        _loopPatternSteps = const [];
        _loopPatternBaseSpeed = null;
      }

      // LoopExecutor와 반복 횟수 정보 동기화
      _loopRepeat = _loopExec.repeat;
      _loopRemaining = _loopExec.remaining;
      _wf.loopRepeat.value = _loopRepeat;

      if (baseSpeed != null) {
        _speed = baseSpeed;
      }
    });

    if (baseSpeed != null) {
      // 엔진 템포 복구
      unawaited(EngineApi.instance.setTempo(baseSpeed));
      // 한 번 복구했으면 다음 패턴을 위해 비워 둔다.
      _loopPatternBaseSpeed = null;
    }

    if (hadPatternState) {
      _logSoTScreen(
        'LOOP_PATTERN_RESET restoreTempo=$restoreTempo clearSteps=$clearSteps',
        startCue: _startCue,
        loopA: _loopA,
        loopB: _loopB,
      );
    }
  }

  /// 🔴 "패턴 OFF" 전용:
  ///  - _loopPatternActive 만 끈다.
  ///  - 현재 템포(_speed)는 그대로 유지.
  ///  - 패턴 스텝 정의(_loopPatternSteps)는 그대로 둔다.
  ///  - LoopExecutor.repeat 를 다시 유저 설정(_loopRepeat)에 맞게 되돌린다.
  void _disableLoopPatternOnly() {
    // 이미 완전히 꺼져 있으면 무시
    if (!_loopPatternActive && _loopPatternStepRemaining <= 0) {
      return;
    }

    // 실행기는 "일반 반복 모드"로 복귀
    _loopExec.setRepeat(_loopRepeat.clamp(0, 200));
    _loopExec.setLoopEnabled(_loopEnabled);

    setState(() {
      _loopPatternActive = false;
      _loopPatternIndex = 0;
      _loopPatternStepRemaining = 0;

      // 템포는 건드리지 않는다.
      // _loopPatternBaseSpeed 도 그대로 둔다 (나중에 완전 리셋 시에만 사용)

      _loopRemaining = _loopExec.remaining;
      _wf.loopRepeat.value = _loopRepeat;
    });

    _logSoTScreen(
      'LOOP_PATTERN_DISABLED_ONLY',
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }

  /// 루프 한 바퀴 종료 / 트랙 자연 종료를 공통으로 처리하는 엔트리
  ///
  /// - fromTrackEnd == false : LoopExecutor.onExitLoop 에서 호출
  /// - fromTrackEnd == true  : EngineApi.trackCompletedHandler 에서 호출
  Future<void> _handleLoopOrTrackExit({required bool fromTrackEnd}) async {
    if (_isDisposing) return;

    bool patternFinished = false;

    // 🔁 패턴 모드인 경우: 한 바퀴 끝날 때마다(또는 트랙 끝날 때) 여기로 들어온다고 가정
    if (_loopPatternActive && _loopPatternSteps.isNotEmpty) {
      // 1) 현재 스텝 남은 횟수 감소
      if (_loopPatternStepRemaining > 0) {
        _loopPatternStepRemaining--;
      }

      setState(() {
        _loopRemaining = _loopPatternStepRemaining;
      });

      // 2) 아직 이 스텝에서 남은 반복이 있다면 → 같은 스텝 다시 실행
      if (_loopPatternStepRemaining > 0) {
        final target = _patternStartTarget;
        final shouldResume = _loopExecCanDrivePlayback;

        _logSoTScreen(
          fromTrackEnd
              ? 'LOOP_PATTERN_STEP_REPEAT_BY_TRACK_END idx=$_loopPatternIndex remain=$_loopPatternStepRemaining'
              : 'LOOP_PATTERN_STEP_REPEAT idx=$_loopPatternIndex remain=$_loopPatternStepRemaining',
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
        );

        _loopExec.setLoopEnabled(true);
        _loopExec.setRepeat(1);

        await _engineSeekFromScreen(target, resumePlaying: shouldResume);
        return;
      }

      // 3) 이 스텝의 반복이 모두 끝났다면 → 다음 스텝으로 넘어갈지 검사
      final nextIndex = _loopPatternIndex + 1;
      if (nextIndex < _loopPatternSteps.length) {
        _logSoTScreen(
          fromTrackEnd
              ? 'LOOP_PATTERN_STEP_EXIT_BY_TRACK_END idx=$_loopPatternIndex → $nextIndex'
              : 'LOOP_PATTERN_STEP_EXIT idx=$_loopPatternIndex → $nextIndex',
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
        );

        // 다음 스텝으로 진입: 카운터는 새 스텝 repeat로 리셋
        _applyLoopPatternStepSync(
          nextIndex,
          resetCounter: true,
          logTag: fromTrackEnd ? 'STEP_ENTER_BY_TRACK_END' : 'STEP_ENTER',
        );

        final target = _patternStartTarget;
        final shouldResume = _loopExecCanDrivePlayback;

        await _engineSeekFromScreen(target, resumePlaying: shouldResume);
        return;
      } else {
        // 4) 마지막 스텝까지 모두 끝났다면 → 패턴 모드 종료
        patternFinished = true;
        _loopPatternActive = false;
        _loopPatternIndex = 0;
        _loopPatternStepRemaining = 0;

        _logSoTScreen(
          fromTrackEnd
              ? 'LOOP_PATTERN_FINISHED_BY_TRACK_END steps=${_loopPatternSteps.length}'
              : 'LOOP_PATTERN_FINISHED steps=${_loopPatternSteps.length}',
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
        );
      }
    }

    // 🔻 여기부터는 "패턴이 아니거나(일반 루프) / 패턴이 완전히 끝난" 공통 종료 처리

    // 1) 실행기 상태 정리
    _loopExec.setLoopEnabled(false);
    _loopExec.setRepeat(0);

    // 2) 화면/웨이브폼 상태 정리
    setState(() {
      _loopEnabled = false;
      _loopRemaining = 0;
      _wf.setLoop(a: _loopA, b: _loopB, on: false);
    });

    // 3) StartCue로 시킹 (+ 기존 Step3 규칙 유지: StartCue에서 자동 재생)
    await EngineApi.instance.loopExitToStartCue(_startCue);

    if (patternFinished) {
      // 🔚 패턴 전체가 끝났으면 "재생도 멈춰 있는 상태" + 템포 복귀
      await EngineApi.instance.pause();
      _loopExecCanDrivePlayback = false;

      // 패턴 상태/카운터/템포 모두 리셋 (스텝 정의는 유지)
      _resetLoopPattern(restoreTempo: true, clearSteps: false);

      _logSoTScreen(
        fromTrackEnd
            ? 'LOOP_PATTERN_STOP_AT_END_BY_TRACK_END'
            : 'LOOP_PATTERN_STOP_AT_END',
        startCue: _startCue,
        loopA: _loopA,
        loopB: _loopB,
      );
    }

    
  }

  /// EngineApi(SoT)가 "트랙 자연 종료"를 감지했을 때 진입하는 엔트리
  Future<void> _onEngineTrackCompleted() async {
    if (!mounted || _isDisposing) return;

    _logSoTScreen(
      'TRACK_COMPLETED_FROM_ENGINE',
      pos: _position,
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );

    await _handleLoopOrTrackExit(fromTrackEnd: true);
  }



// ===== Unified EngineApi fields (Step 4-1) =====
Duration _duration = Duration.zero; // engine_api onDuration 콜백에서 갱신됨
Duration get _position => _wf.position.value;

void _onScrollTick() {
if (!mounted) return;
setState(() {}); // 스크롤 오프셋 변화에 맞춰 오버레이 재계산
}

// 시작점
Duration _startCue = Duration.zero;

// ===== Timed state normalization snapshot (change detection) =====
Duration? _lastNormLoopA;
Duration? _lastNormLoopB;
bool _lastNormLoopEnabled = false;
Duration _lastNormStartCue = Duration.zero;
Duration _lastNormDuration = Duration.zero;

// 🔥 Timed state 정규화 재진입 가드 (StackOverflow 방지용)
bool _isNormalizingTimedState = false;

bool _isDisposing = false; // ✅ dispose 중 가드
VoidCallback? _saverListener; // ✅ 리스너 핸들 보관

// 마커
final List<MarkerPoint> _markers = [];

// 마커 네비게이션 커서
//  - Alt+←/→로 점프할 때 마지막으로 이동한 위치를 기준으로 삼는다.
//  - 재생 중에는 _position을, 점프 이후에는 이 커서를 우선 사용.
Duration? _markerNavCursor;

// ===== 마커 라벨/송폼 헬퍼 =====

// 1-based index → A,B,C,..., Z, AA, AB ...
String _lettersForIndex(int index) {
var n = index;
final codeUnits = <int>[];
while (n > 0) {
n -= 1;
codeUnits.insert(0, 65 + (n % 26));
n ~/= 26;
}
return String.fromCharCodes(codeUnits);
}

static const List<String> _markerSongFormLabels = [
'Intro',
'Verse',
'Pre-Chorus',
'Chorus',
'Bridge',
'Instrumental',
'Solo',
'Outro',
];

bool _isSongFormLabel(String? label) {
if (label == null) return false;
final l = label.trim();
if (l.isEmpty) return false;
for (final s in _markerSongFormLabels) {
if (s.toLowerCase() == l.toLowerCase()) return true;
}
return false;
}

bool _isAutoLetterLabel(String? label) {
if (label == null) return false;
final trimmed = label.trim();
if (trimmed.length != 1) return false;
final code = trimmed.codeUnitAt(0);
return code >= 65 && code <= 90; // 'A'..'Z'
}

// 타임라인 순서 기준으로 A,B,C... 라벨 재부여 + 패널 순서 정렬
//
// - Song Form 라벨(Verse, Chorus...)은 이름 유지 + 시간순으로만 재배치
// - 텍스트 직접 입력 라벨도 이름 유지
// - 라벨이 비어있거나 자동 레터(A,B,C...)인 마커만 A,B,C... 재할당
void _relabelMarkersByTime() {
if (_markers.isEmpty) return;


// 시간 기준 정렬
final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));

for (int i = 0; i < sorted.length; i++) {
  final m = sorted[i];
  final label = m.label?.trim() ?? '';

  final isSongForm = _isSongFormLabel(label);
  final isCustomText =
      label.isNotEmpty && !isSongForm && !_isAutoLetterLabel(label);

  // SongForm / 커스텀 텍스트 라벨은 손대지 않는다.
  if (isSongForm || isCustomText) {
    continue;
  }

  // 나머지(비어있거나, 기존 A,B,C...였던 것)는 A,B,C 시퀀스로 재할당
  m.label = _lettersForIndex(i + 1);
}

_markers
  ..clear()
  ..addAll(sorted);


}

// 패널(리스트) 순서를 기준으로 A,B,C... 재부여
//
// - Song Form 라벨은 유지
// - 사용자가 직접 적은 텍스트 라벨도 유지
// - 자동 A,B,C...만 "현재 리스트 index" 기준으로 다시 배치
void _relabelMarkersByListOrder() {
if (_markers.isEmpty) return;


for (int i = 0; i < _markers.length; i++) {
  final m = _markers[i];
  final label = m.label?.trim() ?? '';

  final isSongForm = _isSongFormLabel(label);
  final isCustomText =
      label.isNotEmpty && !isSongForm && !_isAutoLetterLabel(label);

  if (isSongForm || isCustomText) {
    // 사용자가 명시적으로 정한 라벨은 그대로 둔다.
    continue;
  }

  // 자동 레터 라벨 / 비어 있는 라벨만 A,B,C...로 재할당
  m.label = _lettersForIndex(i + 1);
}


}

// 패널(마커 리스트)에서 순서를 바꿨을 때:
// - 마커의 시간(t)은 그대로 유지
// - 리스트 순서만 변경
// - 자동 A,B,C... 라벨은 "현재 리스트 순서" 기준으로 재부여
void _onMarkerReorder(int oldIndex, int newIndex) {
if (oldIndex < 0 || oldIndex >= _markers.length) return;
if (newIndex < 0 || newIndex > _markers.length) return;


setState(() {
  // Flutter ReorderableListView 규칙:
  // 뒤쪽으로 이동할 때는 제거 후 인덱스가 하나 당겨지므로 보정 필요
  var target = newIndex;
  if (oldIndex < newIndex) {
    target -= 1;
  }

  if (target < 0 || target >= _markers.length) return;

  final item = _markers.removeAt(oldIndex);
  _markers.insert(target, item);

  // 패널 순서를 기준으로 A,B,C... 재라벨링
  _relabelMarkersByListOrder();
});

// WaveformController에도 동일 순서를 반영
_syncMarkersToWaveform();

// 사이드카에도 저장 (메모는 굳이 안 저장해도 됨)
_requestSave(saveMemo: false);


}

// ===== WaveformController <-> Screen 마커 동기화 헬퍼 =====
void _syncMarkersToWaveform() {
// onMarkersChanged 콜백에서 다시 여기로 들어오지 않도록 가드
_suppressWaveformMarkerEvents = true;
try {
_wf.setMarkers(
_markers
.map(
(m) => WfMarker.named(
time: m.t,
// null 방지 + 공백 정리: Panel/MarkerPanel 모두 같은 기준 사용
label: (m.label ?? '').trim(),
color: m.color,
),
)
.toList(),
);
} finally {
_suppressWaveformMarkerEvents = false;
}
}

// 메모
String _notes = '';
final TextEditingController _notesCtl = TextEditingController();
bool _notesInitApplying = true;

Timer? _afWatchdog;

// 자동 저장
Timer? _saveDebounce;

// ✅ 저장 상태(공용 UI 연동)
SaveStatus _saveStatus = SaveStatus.idle;
DateTime? _lastSavedAt;
int _pendingRetryCount = 0;

// 워치독
Timer? _posWatchdog;

// 오늘 날짜
late final String _todayDateStr = () {
final now = DateTime.now();
final d0 = DateTime(now.year, now.month, now.day);
return d0.toIso8601String().split('T').first;
}();

// ===== 사이드카 경로(로컬) =====
String get _cacheDir {
final wsRoot = Directory(widget.studentDir).parent.parent.path;
return p.join(wsRoot, '.cache');
}

// WaveformController.setMarkers() 호출 시 onMarkersChanged 루프 방지용
bool _suppressWaveformMarkerEvents = false;

// ===== Screen-level EngineApi 호출 가드 상태 =====
bool _seekInFlight = false;
Duration? _seekInFlightTarget;

bool _playInFlight = false;

// 🔥 LoopExecutor가 자동으로 재생을 트리거해도 되는지 여부
//  - Space로 정지한 상태에서는 false
//  - 사용자가 재생을 명시적으로 시작하면 true
bool _loopExecCanDrivePlayback = false;

// 🔥 Space(Play/Pause) 입력 가드 (key repeat / 중복 호출 방지)
DateTime? _lastSpaceInvokedAt;
bool _spaceInFlight = false;

@override
void initState() {
super.initState();


// 1) LoopExecutor 초기화
_loopExec = LoopExecutor(
  getPosition: () => _wf.position.value,
  getDuration: () => _wf.duration.value,
  // ✅ Screen-level seek 게이트 사용
  seek: (d) => _engineSeekFromScreen(d),
  // ✅ Screen-level play 게이트 사용 + 정지 상태 자동 재생 차단
  play: () async {
    if (!_loopExecCanDrivePlayback) {
      _logSoTScreen('LOOP_EXEC_PLAY_SUPPRESSED (auto-play disabled)');
      return;
    }
    await _enginePlayFromScreen();
  },
  pause: () => EngineApi.instance.pause(),
    onLoopStateChanged: (enabled) {
        setState(() {
          _wf.setLoop(a: _loopA, b: _loopB, on: _loopExec.loopOn);
        });
      },
      onLoopRemainingChanged: (rem) {
        // 패턴 모드에서는 LoopExecutor의 remaining 값은
        // 신뢰하지 않고, 우리가 관리하는 _loopPatternStepRemaining 사용
        if (_loopPatternActive && _loopPatternSteps.isNotEmpty) {
          return;
        }
        setState(() => _loopRemaining = rem);
      },
                    onExitLoop: () async {
        // 🔁 루프 한 바퀴 정상 종료 시
        await _handleLoopOrTrackExit(fromTrackEnd: false);
      },

);

_loopExec.start();

// A 패치: 라이프사이클 옵저버 등록
WidgetsBinding.instance.addObserver(this);

// ✅ 트랜스크라이브 톤(VisualExact + Signed) 기본 적용
WaveformTuning.I.applyPreset(WaveformPreset.transcribeLike);
WaveformTuning.I
  ..visualExact = true
  ..useSignedAmplitude = true;

// saver 초기화 + 상태 listen
_saver = DebouncedSaver(delay: const Duration(milliseconds: 800));
_saverListener = () {
  if (!mounted || _isDisposing) return;
  setState(() {
    _saveStatus = _saver.status;
    _lastSavedAt = _saver.lastSavedAt;
    _pendingRetryCount = _saver.pendingRetryCount;
  });
};
_saver.addListener(_saverListener!);

// === 컨트롤러 콜백 (패널 → 화면/플레이어) ===
_gestures = SmpWaveformGestures(
  waveform: _wf,
  onPause: () => EngineApi.instance.pause(),
  getDuration: () => _duration,
  getStartCue: () => _startCue,
  setStartCue: (d) {
    // P3 규칙:
    //  - Loop ON/OFF와 무관하게 StartCue는 언제든지 수정 가능
    //  - 단, 유효한 루프가 있을 경우 "루프 밖이면 앞점(A)로 스냅"만 적용
    final fixed = _normalizeStartCueForLoop(d);

    setState(() {
      _startCue = fixed;
    });

    // WaveformController에도 즉시 반영
    _wf.setStartCue(_startCue);

    _logSoTScreen('START_CUE set via gesture', startCue: fixed);
  },
  setPosition: (d) {
    // no-op: pos는 EngineApi.position 스트림 → WaveformController 단일 경로
  },
  onSeekRequest: (d) async {
    // 🔥 P3 공통 규칙:
    //  - 재생 중이면 seek 후 계속 재생
    //  - 정지면 seek 후 정지 유지
    //  - Loop/StartCue는 이 경로에서 상/하한으로 개입하지 않음
    await _engineSeekAndMaybeResumeFromScreen(d);
    _requestSave(saveMemo: false);
  },
  saveDebounced: ({saveMemo = false}) => _requestSave(saveMemo: saveMemo),
  isPlaying: () => EngineApi.instance.isPlaying,
);

// 파형 기본 힌트 (duration unknown 시)
_wf.updateFromPlayer(dur: const Duration(minutes: 5));

// 제스처 시스템 attach (WaveformController 연결)
_gestures.attach(); // Step 6-B: duration 반영 이후 attach
// 제스처(WaveformPanel) → Screen 콜백 연결
_wf.onLoopSet = _onLoopSetFromPanel;
_wf.onStartCueSet = _onStartCueFromPanel;
_wf.onMarkersChanged = _onMarkersChangedFromWaveform; // 🔹 NEW: 마커 동기화

// [7-A] PIP auto-collapse 동작을 위한 scroll listener 연결
_scrollCtl.addListener(_onScrollTick);

// 🔸 1차 프레임: UI 먼저 그리기 (StickyVideoOverlay 자리 포함)
WidgetsBinding.instance.addPostFrameCallback((_) {
  if (!mounted) return;

  _focusNode.requestFocus();

  // 🔸 2차 프레임: 레이아웃이 잡힌 뒤에 엔진 로드
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    _initAsync();
  });
});

// [SYNC]
_initNotesAndSidecarSync();
_subscribeLocalNotesBus();
_startPosWatchdog();

// 초기 브릿지: Loop/StartCue/Marker → WaveformController
_wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
_wf.setStartCue(_startCue);
// EngineApi가 StartCue를 항상 Screen 상태에서 가져가도록 연결
EngineApi.instance.startCueProvider = () => _startCue;
// 🔥 EngineApi 트랙 완료 이벤트를 패턴/LoopExecutor 엔진으로 위임
    EngineApi.instance.trackCompletedHandler = _onEngineTrackCompleted;

_syncMarkersToWaveform();

// === 3-3B: audioChain playbackTime → position single-source ===
// ✅ P3: _gestures 생성/attach 이후에 position$ listen 등록
_positionSub = EngineApi.instance.position$.listen((d) {
  if (!mounted || _isDisposing) return;

  // 엔진 기준 SoT
  final enginePos = d;
  final engineDur = _wf.duration.value > Duration.zero
      ? _wf.duration.value
      : _duration;

  // ✅ 단일 진입점: WaveformController에 pos/dur 동기화
  _wf.updateFromPlayer(pos: enginePos, dur: engineDur);

  // TransportBar 등 전체 UI 갱신
  setState(() {});
});


}

// A 패치: 앱 라이프사이클 변화 시 즉시 저장 한번 보장
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
if (state == AppLifecycleState.inactive ||
state == AppLifecycleState.paused) {
unawaited(
_saver.flush(() async {
// 1) 사이드카 즉시 저장
await _saveEverything(saveMemo: false);


      // 2) flush 이후 DB 업로드 pending 체크
      final pending = SidecarSyncDb.instance.pendingUploadAt;
      if (pending != null) {
        // 즉시 업로드 시도 (실패하면 pending 유지됨)
        unawaited(SidecarSyncDb.instance.tryUploadNow());
      }
    }),
  );
}


}

Future<void> _initAsync() async {
await _openMedia();
}

// =========================
// [SYNC] 초기 동기화 시퀀스
// =========================
Future<void> _initNotesAndSidecarSync() async {
_notesInitApplying = true;
try {
// 1) DB판 바인딩(+로컬 캐시 경로 전달)
await SidecarSyncDb.instance.bind(
studentId: widget.studentId,
mediaHash: widget.mediaHash,
localCacheDir: _cacheDir, // 선택
);
// 2) 없으면 생성
await SidecarSyncDb.instance.upsertInitial(initial: const {});
// 3) 로컬→DB 순서로 로드
final loaded = await SidecarSyncDb.instance.load();
if (loaded.isNotEmpty) _applySidecarMap(loaded);

// 2) lessons.memo 초기값
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


  // 3) Realtime 구독
  _subscribeLessonMemoRealtime();
} finally {
  _notesInitApplying = false;
}
_requestSave(saveMemo: false);


}

void _subscribeLessonMemoRealtime() {
final today = _todayDateStr;


LessonMemoSync.instance.subscribeRealtime(
  studentId: widget.studentId,
  dateISO: today,
  onMemoChanged: (memo) {
    if (!mounted) return;

    // 변경 없음 → 무시
    if (memo == _notes) return;

    // hydration 시작
    _hydratingMemo = true;

    setState(() {
      _notes = memo;
      _notesCtl.text = memo;
    });

    // sidecar 저장은 hydration 종료 후로 지연
    Future.delayed(const Duration(milliseconds: 50), () {
      _hydratingMemo = false;
      _requestSave(saveMemo: false);
    });
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

  Future.delayed(const Duration(milliseconds: 50), () {
    _hydratingMemo = false;
    _requestSave(saveMemo: true);
  });
});


}

@override
void dispose() {
_isDisposing = true;


// P1: 좀비 재생 방지 — 화면 종료 시 엔진/플레이어 완전 정리
unawaited(EngineApi.instance.stopAndUnload());
// 이 Screen이 사라질 땐 StartCue provider도 정리
EngineApi.instance.startCueProvider = null;
    // 트랙 완료 콜백도 해제 (다른 Screen에서 새로 설정 가능해야 함)
    EngineApi.instance.trackCompletedHandler = null;


_positionSub?.cancel();
_positionSub = null;

if (_saverListener != null) {
  _saver.removeListener(_saverListener!);
  _saverListener = null;
}

try {
  unawaited(
    _saver.flush(() async {
      await _saveEverything(saveMemo: false);
    }),
  );
} catch (_) {}

_saver.dispose();
SidecarSyncDb.instance.dispose();
LessonMemoSync.instance.dispose();
_loopExec.stop();
WidgetsBinding.instance.removeObserver(this);
_notesCtl.dispose();
_focusNode.dispose();
_posWatchdog?.cancel();
_scrollCtl.dispose();
_applyDebounce?.cancel();
_afWatchdog?.cancel();
_saveDebounce?.cancel();
_gestures.dispose();

super.dispose();


}

void _applySidecarMap(Map<String, dynamic> m) {
    final a = m['loopA'];
    final b = m['loopB'];
    final sp = m['speed'] ?? 1.0;
    final posMsRaw = m['positionMs'];
    final mk = (m['markers'] as List?)?.cast<dynamic>() ?? const [];
    final ps = m['pitchSemi'] ?? 0;
    final rpRaw = m['loopRepeat'] ?? 0;
    final scRaw = m['startCueMs'];
    final notes = (m['notes'] as String?) ?? '';
    final vol = m['volume'] ?? 100;

    // 🔹 NEW: 패턴 스텝 로딩
    final lpStepsRaw = m['loopPatternSteps'];

    final loopAms = (a is num) ? a.toInt() : 0;
    final loopBms = (b is num) ? b.toInt() : 0;
    final posMs = (posMsRaw is num) ? posMsRaw.toInt() : 0;
    final scMs = (scRaw is num) ? scRaw.toInt() : 0;

    // 🔹 NEW: 사이드카에 저장된 패턴 스텝 복원
    List<_LoopPatternStep> restoredPatternSteps = _loopPatternSteps;
    if (lpStepsRaw is List) {
      restoredPatternSteps = lpStepsRaw.whereType<Map>().map((e) {
        final tempo = ((e['tempo'] as num?) ?? 1.0).toDouble();
        final repeats = ((e['repeats'] as num?) ?? 1).toInt();
        return _LoopPatternStep(
          tempo: tempo.clamp(0.5, 1.5),
          repeats: repeats.clamp(1, 200),
        );
      }).toList();
    }

    setState(() {
      _loopA = loopAms > 0 ? Duration(milliseconds: loopAms) : null;
      _loopB = loopBms > 0 ? Duration(milliseconds: loopBms) : null;

      final loopOnWant = (m['loopOn'] ?? false) == true;
      _loopEnabled =
          loopOnWant && _loopA != null && _loopB != null && _loopA! < _loopB!;

      _speed = (sp as num).toDouble().clamp(0.5, 1.5);
      _loopRepeat = (rpRaw as num).toInt().clamp(0, 200);
      _loopRemaining = -1;
      _pitchSemi = (ps as num).toInt().clamp(-7, 7);

      _startCue = Duration(milliseconds: scMs);

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
      _markerNavCursor = null;

      // 🔹 NEW: 패턴 설정값(템포/횟수 리스트)만 복원, 상태는 항상 OFF로 시작
      _loopPatternSteps = restoredPatternSteps;
      _loopPatternActive = false;
      _loopPatternIndex = 0;
      _loopPatternStepRemaining = 0;
      _loopPatternBaseSpeed = null;

      _normalizeTimedState();
    });


// 🔁 LoopExecutor / WaveformController와 동기화
if (_loopEnabled && _loopA != null && _loopB != null) {
  _loopExec.setA(_loopA!);
  _loopExec.setB(_loopB!);
  _loopExec.setLoopEnabled(true);
} else {
  _loopExec.setLoopEnabled(false);
}
_loopExec.setRepeat(_loopRepeat);

setState(() {
  _loopRemaining = _loopExec.remaining;
});
_wf.loopRepeat.value = _loopRepeat;

_logSoTScreen(
  'APPLY_SIDECAR (loop/startCue restored)',
  loopA: _loopA,
  loopB: _loopB,
  startCue: _startCue,
);

if (posMs > 0) {
  final d = Duration(milliseconds: posMs);

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final dur = _effectiveDuration;
    if (dur != Duration.zero && d < dur) {
      await _engineSeekFromScreen(d);
    }
  });
}

_wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
_wf.setStartCue(_startCue);
_syncMarkersToWaveform();

final effDur = _effectiveDuration;
if (effDur != Duration.zero) {
  _wf.setDuration(effDur);
  _wf.updateFromPlayer(dur: effDur);
}


}

void _startPosWatchdog() {
_posWatchdog?.cancel();
const period = Duration(seconds: 1);


int steadyTicks = 0;
bool reportedInThisSpan = false;
Duration last = Duration.zero;

_posWatchdog = Timer.periodic(period, (_) {
  if (!mounted || _isDisposing) return;

  final playing = EngineApi.instance.isPlaying;
  final current = _position;

  // 위치가 바뀌면 → 새 구간 시작
  if (current != last) {
    last = current;
    steadyTicks = 0;
    reportedInThisSpan = false;
    return;
  }

  // 위치는 그대로인데, 재생 중이 아니면 → 정지 상태이므로 무시
  if (!playing) {
    return;
  }

  // 재생 중 + 위치가 1초 이상 동일할 때 카운트
  steadyTicks++;

  // 5초 동안 그대로일 때 한 번만 로그
  if (!reportedInThisSpan && steadyTicks >= 5) {
    debugPrint(
      '[SMP] position steady 5s while playing (pos=${current.inMilliseconds}ms)',
    );
    _logSoTScreen('WATCHDOG steady 5s', pos: current);
    reportedInThisSpan = true;
  }
});


}

Future<void> _openMedia() async {
await EngineApi.instance.load(
path: widget.mediaPath,
onDuration: (d) {
final engineDuration = d;
final waveDuration = _wf.duration.value;


    final safeDuration = engineDuration > Duration.zero
        ? engineDuration
        : (waveDuration > Duration.zero ? waveDuration : Duration.zero);

    setState(() {
      _duration = safeDuration;
      _normalizeTimedState();
    });

    _wf.setDuration(safeDuration);
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isDisposing) {
        _wf.updateFromPlayer(dur: safeDuration);
        setState(() {});
      }
    });
  },
);

_logSoTScreen('OPEN_MEDIA done (duration=${_fmt(_duration)})');


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
Text('재생/일시정지(시작점): Space'),
Text('루프 토글: L  •  루프 시작/끝 지정: E / D'),
Text('마커 추가: M'),
Text('마커 점프: Alt+1~9  •  이전/다음: Alt+←/→'),
Text('템포 조절: [ 5% 느리게  ,  ] 5% 빠르게'),
Text('템포 프리셋: 5~0 = 50%~100%'),
Text('키 조정(반음): Alt+↑ / Alt+↓'),
SizedBox(height: 8),
Text('  =  키를 누르고 있는 동안 4x 재생'),
Text('  -  키를 누르고 있는 동안 4x 역재생'),
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

void _requestSave({bool saveMemo = true}) {
if (_isDisposing) return;


_saver.schedule(() async {
  if (_isDisposing) return;
  await _saveEverything(saveMemo: saveMemo);
});


}

Future<void> _saveEverything({bool saveMemo = true}) async {
// dispose 중에도 마지막 flush 저장은 허용해야 하므로
// 여기서는 _isDisposing 으로 early-return 하지 않는다.


// 메모 동기화 중일 때는 DB memo만 막고, sidecar는 계속 저장한다.
if (_hydratingMemo && saveMemo) {
  saveMemo = false;
}

final now = DateTime.now();

    // 저장 직전에 한번 더 정규화
    _normalizeTimedState();

    final map = {
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
      'savedAt': now.toIso8601String(),
      'media': p.basename(widget.mediaPath),
      'version': 'v3.07.2',
      'markers': _markers.map((e) => e.toJson()).toList(),
      'notes': _notes,
      'volume': _volume,

      // 🔹 NEW: 루프 패턴 스텝 저장 (tempo: 0.5~1.5, repeats: 1~200)
      'loopPatternSteps': _loopPatternSteps
          .map((s) => {'tempo': s.tempo, 'repeats': s.repeats})
          .toList(),
    };

    try {
      await SidecarSyncDb.instance.save(map, debounce: false);
  // 2) 메모는 hydration 중이 아닐 때만 DB에 반영
  if (saveMemo && !_hydratingMemo) {
    await LessonMemoSync.instance.upsertMemo(
      studentId: widget.studentId,
      dateISO: _todayDateStr,
      memo: _notes,
    );
  }

  // 3) 가능하면 즉시 업로드 시도
  await SidecarSyncDb.instance.tryUploadNow();

  // 🔒 dispose 중에는 setState 금지
  final canTouchUi = mounted && !_isDisposing;
  if (canTouchUi) {
    setState(() {
      _saveStatus = SaveStatus.saved;
      _lastSavedAt = now;
      _pendingRetryCount = 0;
    });
  }
} catch (_) {
  // UI 업데이트는 dispose 중엔 하지 않음
  if (!mounted || _isDisposing) return;
  setState(() => _saveStatus = SaveStatus.failed);
}


}

Future<void> _startHoldFastForward() async {
await EngineApi.instance.ffrw.startForward(
startCue: _startCue, // 🔁 기존: Duration.zero
loopA: _loopA, // 🔁 기존: null
loopB: _loopB, // 🔁 기존: null
loopOn: _loopEnabled, // 🔁 기존: false
);
setState(() {});
}

Future<void> _stopHoldFastForward() => EngineApi.instance.ffrw.stopForward();

Future<void> _startHoldFastReverse() async {
await EngineApi.instance.ffrw.startReverse(
startCue: _startCue, // 🔁 기존: Duration.zero
loopA: _loopA, // 🔁 기존: null
loopB: _loopB, // 🔁 기존: null
loopOn: _loopEnabled, // 🔁 기존: false
);
}

Future<void> _stopHoldFastReverse() => EngineApi.instance.ffrw.stopReverse();

Duration _clamp(Duration x, Duration min, Duration max) {
if (x < min) return min;
if (x > max) return max;
return x;
}

Duration get _effectiveDuration {
if (_duration > Duration.zero) return _duration;
if (_wf.duration.value > Duration.zero) return _wf.duration.value;
return Duration.zero;
}

/// WaveformPanel(드래그/핸들/더블탭)에서 올라오는 루프 설정 요청
  ///
  /// R1. 루프 영역 있으면 → loopOn 무조건 true
  /// R2. 루프 영역 있으면 → StartCue 항상 A에 붙는다
  /// R3. 드래그로 루프 영역 만든 순간 A/B 정렬 + loopOn=true + StartCue=A
  /// R4. 루프 영역 해제(null,null) 시 → 루프 OFF + 영역 제거
  void _onLoopSetFromPanel(Duration? a, Duration? b) {
    if (_isDisposing) return;

    final dur = _effectiveDuration;

    Duration? newA = a;
    Duration? newB = b;

    // duration 범위 안으로 클램프
    if (dur > Duration.zero) {
      if (newA != null) newA = _clamp(newA, Duration.zero, dur);
      if (newB != null) newB = _clamp(newB, Duration.zero, dur);
    }

    final bool hasLoop = newA != null && newB != null && newA! < newB!;

    if (!hasLoop) {
      // 루프 해제: 패턴도 실행만 끄고, 스텝/템포는 유지
      _disableLoopPatternOnly();

      setState(() {
        _loopA = null;
        _loopB = null;
        _loopEnabled = false;
      });

      _loopExec.setLoopEnabled(false);
      _wf.setLoop(a: null, b: null, on: false);

      _logSoTScreen('LOOP_CLEAR_FROM_PANEL');
      _requestSave(saveMemo: false);

      // 🔥 최종 상태 정리
      _reconcileLoopAndPattern('LOOP_CLEAR_FROM_PANEL');
      return;
    }

    final aa = newA!;
    final bb = newB!;

    final newStartCue = (dur > Duration.zero)
        ? _clamp(aa, Duration.zero, dur)
        : aa;

    setState(() {
      _loopA = aa;
      _loopB = bb;
      _loopEnabled = true;
      _startCue = newStartCue;
    });

    _loopExec.setA(aa);
    _loopExec.setB(bb);
    _loopExec.setLoopEnabled(true);

    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    _logSoTScreen(
      'LOOP_SET_FROM_PANEL',
      loopA: _loopA,
      loopB: _loopB,
      startCue: _startCue,
    );
    _requestSave(saveMemo: false);

    // 🔥 최종 상태 정리
    _reconcileLoopAndPattern('LOOP_SET_FROM_PANEL');
  }

/// WaveformPanel(클릭/드래그 시작점 등)에서 올라오는 StartCue 후보
///
/// - 루프 없으면: 단순히 0~duration 안으로만 클램프
/// - 루프 있으면: R2에 따라 항상 루프 안, 필요 시 A로 스냅
  void _onStartCueFromPanel(Duration candidate) {
    if (_isDisposing) return;

    final fixed = _normalizeStartCueForLoop(candidate);
    if (fixed == _startCue) {
      return;
    }

    setState(() {
      _startCue = fixed;
    });

    _wf.setStartCue(_startCue);

    _logSoTScreen('START_CUE_FROM_PANEL', startCue: _startCue);
    _requestSave(saveMemo: false);

    // 🔥 최종 상태 정리
    _reconcileLoopAndPattern('START_CUE_FROM_PANEL');
  }


void _normalizeTimedState() {
    if (_isNormalizingTimedState) {
      _logSoTScreen('NORMALIZE_TIMED_STATE_SKIP (reentrant)', pos: _position);
      return;
    }

    _isNormalizingTimedState = true;
    try {
      final dur = _effectiveDuration;
      Duration? newA = _loopA;
      Duration? newB = _loopB;
      bool newLoopOn = _loopEnabled;
      Duration newStartCue = _startCue;

  if (dur <= Duration.zero) {
    if (newA != null && newA < Duration.zero) {
      newA = Duration.zero;
    }
    if (newB != null && newB < Duration.zero) {
      newB = Duration.zero;
    }
    if (newStartCue < Duration.zero) {
      newStartCue = Duration.zero;
    }
  } else {
    // 1) A/B를 duration 안으로 클램프
    if (newA != null) {
      newA = _clamp(newA, Duration.zero, dur);
    }
    if (newB != null) {
      newB = _clamp(newB, Duration.zero, dur);
    }

    // 2) 루프 유효성 판정
    //
    //    🔥 변경 포인트:
    //    - "A만 있고 B는 없는 상태"는 정상적인 "임시 A" 상태로 인정한다.
    //    - 실제 루프 유효성(loopValid)은 A/B 둘 다 있을 때만 검사한다.
        bool loopValid = false;
        if (newA != null && newB != null) {
          if (newA < newB) {
            loopValid = true;
          } else {
            // A/B 둘 다 있는데 순서가 뒤집힌 것은 깨진 루프 → 둘 다 제거
            newA = null;
            newB = null;
          }
        }
        // newA != null && newB == null (혹은 반대) 인 상태는
        // "부분 설정 상태"로 두고 loopValid = false 그대로 둔다.

        // 🔥 R1 규칙 수정:
        //  - 유효한 루프 영역이 "없으면" loopOn은 항상 false
        //  - 유효한 루프 영역이 "있으면"
        //    사용자가 만든 _loopEnabled 값을 그대로 유지한다.
        //    (패턴 종료 후 loopOff 상태 + A/B만 유지 같은 케이스를 깨지 않기 위함)
        if (!loopValid) {
          newLoopOn = false;
        }
        // loopValid == true 인 경우엔 newLoopOn(= 기존 _loopEnabled)을 존중


    // 3) StartCue 클램프 및 루프 내부 고정 (R2)
    var sc = newStartCue;
    if (sc < Duration.zero) sc = Duration.zero;
    if (sc > dur) sc = dur;

    if (newA != null && newB != null && newA < newB) {
      final a = _clamp(newA, Duration.zero, dur);
      final b = _clamp(newB, Duration.zero, dur);
      if (sc < a || sc > b) {
        sc = a;
      }
    }
    newStartCue = sc;

    // 4) 반복 횟수 범위 정리
    _loopRepeat = _loopRepeat.clamp(0, 200);
  }

  final loopChanged =
      newA != _loopA || newB != _loopB || newLoopOn != _loopEnabled;
  final startCueChanged = newStartCue != _startCue;
  final durationChanged = dur != _lastNormDuration;

  _loopA = newA;
  _loopB = newB;
  _loopEnabled = newLoopOn;
  _startCue = newStartCue;

  if (loopChanged || durationChanged) {
    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
  }
  if (startCueChanged || durationChanged) {
    _wf.setStartCue(_startCue);
  }

  // 🔥 LoopExecutor와도 R1 기준으로 상태 동기화
  if (loopChanged) {
    if (_loopA != null && _loopB != null && _loopA! < _loopB!) {
      // 유효한 루프 영역 → 실행기도 항상 ON
      _loopExec.setA(_loopA!);
      _loopExec.setB(_loopB!);
      _loopExec.setLoopEnabled(_loopEnabled);
    } else {
      // 루프 영역이 없거나 A만 있는 상태 → 실행기 OFF
      _loopExec.setLoopEnabled(false);
    }
  }

  if (loopChanged || startCueChanged || durationChanged) {
    _lastNormLoopA = _loopA;
    _lastNormLoopB = _loopB;
    _lastNormLoopEnabled = _loopEnabled;
    _lastNormStartCue = _startCue;
    _lastNormDuration = dur;

    _logSoTScreen(
      'NORMALIZE_TIMED_STATE',
      pos: _position,
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }
} finally {
  _isNormalizingTimedState = false;
}


}

Future<void> _engineSeekFromScreen(
Duration target, {
bool? resumePlaying,
}) async {
if (_isDisposing) return;


final dur = _effectiveDuration;
var clampedTarget = target;
if (dur > Duration.zero) {
  clampedTarget = _clamp(target, Duration.zero, dur);
} else if (clampedTarget < Duration.zero) {
  clampedTarget = Duration.zero;
}

if (_seekInFlight && _seekInFlightTarget == clampedTarget) {
  _logSoTScreen(
    'SEEK_SCREEN_SKIP (in-flight same target)',
    pos: clampedTarget,
  );
  return;
}

_seekInFlight = true;
_seekInFlightTarget = clampedTarget;

try {
  await EngineApi.instance.seekUnified(
    clampedTarget,
    startCue: _startCue,
    loopA: _loopA,
    loopB: _loopB,
  );
} finally {
  _seekInFlight = false;
}

if (resumePlaying == true && !_isDisposing) {
  await _enginePlayFromScreen();
}


}

Future<void> _engineSeekAndMaybeResumeFromScreen(Duration target) async {
if (_isDisposing) return;


final wasPlaying = EngineApi.instance.isPlaying;
await _engineSeekFromScreen(target, resumePlaying: wasPlaying);


}

Future<void> _enginePlayFromScreen() async {
    if (_isDisposing) return;

    if (_playInFlight) {
      _logSoTScreen('PLAY_SCREEN_SKIP (in-flight)');
      return;
    }

    _playInFlight = true;
    try {
      await EngineApi.instance.play();

      if (_isDisposing) return;

      final nowPlaying = EngineApi.instance.isPlaying;
      _loopExecCanDrivePlayback = nowPlaying;

      // 🔥 패턴 모드가 켜져 있고, 루프도 켜져 있을 때:
      //  - 사용자가 재생을 누르는 시점마다
      //    "현재 스텝의 템포/반복 횟수"를 다시 한 번 정확히 적용해서
      //    이전에 꼬여 있던 LoopExecutor 내부 상태를 덮어쓴다.
      if (nowPlaying &&
          _loopPatternActive &&
          _loopPatternSteps.isNotEmpty &&
          _loopEnabled &&
          _loopA != null &&
          _loopB != null) {
        // 🔹 패턴 재진입 시에도 루프 구간 보정
        _ensurePatternLoopRegion();

        // 카운터 유지 + 템포/LoopExecutor 상태만 재정렬
        _resyncLoopPatternOnPlay();
      }

    } finally {
      _playInFlight = false;
    }
  }


Future<void> _engineSpaceFromScreen() async {
if (_isDisposing) return;


final now = DateTime.now();
final wasPlaying = EngineApi.instance.isPlaying;

if (_spaceInFlight) {
  _logSoTScreen('SPACE_SCREEN_SKIP (in-flight)');
  return;
}

if (_lastSpaceInvokedAt != null &&
    now.difference(_lastSpaceInvokedAt!) <
        const Duration(milliseconds: 150)) {
  _logSoTScreen('SPACE_SCREEN_SKIP (debounced)');
  return;
}

_spaceInFlight = true;
_lastSpaceInvokedAt = now;

try {
  await EngineApi.instance.spaceBehavior(
    _startCue,
    loopA: _loopA,
    loopB: _loopB,
    loopOn: _loopEnabled,
  );
} finally {
  _spaceInFlight = false;

  // 🔹 Space 이후 실제 재생 상태에 맞춰 LoopExecutor 재생 권한 갱신
  if (!_isDisposing) {
    final nowPlaying = EngineApi.instance.isPlaying;
    _loopExecCanDrivePlayback = nowPlaying;
  }
}


}

KeyEventResult _onKeyEvent(FocusNode node, KeyEvent evt) {
    final mods = HardwareKeyboard.instance.logicalKeysPressed;
    final hasBlockMods =
        mods.contains(LogicalKeyboardKey.alt) ||
        mods.contains(LogicalKeyboardKey.altLeft) ||
        mods.contains(LogicalKeyboardKey.altRight) ||
        mods.contains(LogicalKeyboardKey.control) ||
        mods.contains(LogicalKeyboardKey.meta);

    // 0) Space: 재생/일시정지(시작점 기준)
    //
    //  - modifier(Alt/Ctrl/Command) 없이 눌렀을 때만 처리
    //  - KeyDown에서만 한 번 실행 (KeyUp은 무시)
    if (!hasBlockMods && evt.logicalKey == LogicalKeyboardKey.space) {
      if (evt is KeyDownEvent) {
        _engineSpaceFromScreen();
      }
      return KeyEventResult.handled;
    }

    // Alt/Ctrl/Meta가 섞인 키들은 여기서 막고,
    // 기존 SmpsShortcuts 안의 Alt+숫자/화살표/줌 단축키로 보내준다.
    if (hasBlockMods) {
      return KeyEventResult.ignored;
    }

    // 1) '=' 키 → 4x 앞으로(꾹 누르는 동안)
    if (evt.logicalKey == LogicalKeyboardKey.equal) {
      if (evt is KeyDownEvent) {
        EngineApi.instance.ffrw.startForward(
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
          loopOn: _loopEnabled,
        );
      } else if (evt is KeyUpEvent) {
        EngineApi.instance.ffrw.stopForward();
      }
      return KeyEventResult.handled;
    }

    // 2) '-' 키 → 4x 뒤로(꾹 누르는 동안)
    if (evt.logicalKey == LogicalKeyboardKey.minus) {
      if (evt is KeyDownEvent) {
        EngineApi.instance.ffrw.startReverse(
          startCue: _startCue,
          loopA: _loopA,
          loopB: _loopB,
          loopOn: _loopEnabled,
        );
      } else if (evt is KeyUpEvent) {
        EngineApi.instance.ffrw.stopReverse();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }


@override
Widget build(BuildContext context) {
final title = p.basename(widget.mediaPath);

// 1) 파일 확장자로만 "영상 파일 여부" 판정 (레이아웃 높이 결정용)
final ext = p.extension(widget.mediaPath).toLowerCase();
final bool isVideoFile =
    ext == '.mp4' ||
        ext == '.mov' ||
        ext == '.m4v' ||
        ext == '.avi' ||
        ext == '.mkv';

// 2) 실제 비디오 컨트롤러 존재 여부는 별도 (오버레이 표시용)
final videoController = EngineApi.instance.videoController;
final bool hasVideoController = videoController != null;

return Listener(
  onPointerDown: (_) {
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
  },
  child: SmpsShortcuts(
    focusNode: _focusNode,
    onPlayFromStartOrPause: () => _engineSpaceFromScreen(),
    onToggleLoop: () {
      _loopToggleMain(!_loopEnabled);
    },
    onLoopASet: () => _loopSetA(_wf.position.value),
    onLoopBSet: () => _loopSetB(_wf.position.value),
    onMarkerAdd: _addMarker,
    onMarkerJump: (i1based) => _jumpToMarkerIndex(i1based - 1),
    onMarkerPrev: () => _jumpPrevNextMarker(next: false),
    onMarkerNext: () => _jumpPrevNextMarker(next: true),
    onZoom: (zoomIn) {
      final delta = zoomIn ? 1.10 : 0.90;
      _gestures.zoomAt(cursorFrac: 0.5, factor: delta);
    },
    onZoomReset: _gestures.zoomReset,
    onPitchNudge: _pitchDelta,
    onSpeedPreset: _setSpeed,
    onSpeedNudge: _nudgeSpeed,
    onKeyEvent: _onKeyEvent,
    child: Scaffold(
      appBar: AppBar(
        title: Text('스마트 미디어 플레이어 — $title'),
        actions: [
          ValueListenableBuilder<DateTime?>(
            valueListenable: SidecarSyncDb.instance.pendingUploadAtNotifier,
            builder: (ctx, pendingAt, child) {
              final hasPending = pendingAt != null;
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: hasPending
                    ? Container(
                        key: const ValueKey('pending'),
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '업로드 대기중',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              );
            },
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
          final double viewportW = c.maxWidth;
          final double viewportH = c.maxHeight;

          // 🔹 "이 파일이 영상인가?" 기준으로 자리부터 확보
          final double videoMaxHeight =
              isVideoFile ? viewportW * 9 / 16 : 0.0;

          return Stack(
            children: [
              SingleChildScrollView(
                controller: _scrollCtl,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight - 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isVideoFile) ...[
                        // 🔸 영상 컨트롤러가 아직 없어도 "자리"는 먼저 만든다
                        SizedBox(height: videoMaxHeight, width: viewportW),
                        const SizedBox(height: 12),
                      ],
                      AppSection(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: WaveformPanel(
                            controller: _wf,
                            mediaPath: widget.mediaPath,
                            mediaHash: widget.mediaHash,
                            cacheDir: _cacheDir,
                            gestures: _gestures,
                            onStateDirty: () => _requestSave(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      SmpTransportBar(
                            position: _wf.position.value,
                            duration: _wf.duration.value,
                            isPlaying: EngineApi.instance.isPlaying,
                            fmt: _fmt,
                            onPlayPause: () => _engineSpaceFromScreen(),
                            onHoldReverseStart: _startHoldFastReverse,
                            onHoldReverseEnd: _stopHoldFastReverse,
                            onHoldForwardStart: _startHoldFastForward,
                            onHoldForwardEnd: _stopHoldFastForward,
                            loopA: _loopA,
                            loopB: _loopB,
                            loopEnabled: _loopExec.loopOn,
                            loopRepeat: _loopRepeat,
                            loopRemaining: _loopRemaining,
                            loopPatternActive: _loopPatternActive,
                            onLoopASet: () => _loopSetA(_position),
                            onLoopBSet: () => _loopSetB(_position),
                            onLoopToggle: _loopToggleMain,
                            onLoopRepeatMinus1: () => _loopRepeatDelta(-1),
                            onLoopRepeatPlus1: () => _loopRepeatDelta(1),
                            onLoopRepeatLongMinus5: () => _loopRepeatDelta(-5),
                            onLoopRepeatLongPlus5: () => _loopRepeatDelta(5),
                            onLoopRepeatPrompt: _loopPromptRepeat,
                            onZoomOut: () {
                              _gestures.zoomAt(cursorFrac: 0.5, factor: 0.90);
                            },
                            onZoomReset: _gestures.zoomReset,
                            onZoomIn: () {
                              _gestures.zoomAt(cursorFrac: 0.5, factor: 1.10);
                            },
                          ),
                          const SizedBox(height: 4),  

                          SmpControlPanel(
                            speed: _speed,
                            pitchSemi: _pitchSemi,
                            volume: _volume,
                            onSpeedChanged: _setSpeed,
                            onSpeedNudged: _nudgeSpeed,
                            onPitchSet: _setPitch,
                            onPitchNudged: _pitchDelta,
                            onVolumeSet: _setVolume,
                            onVolumeNudged: _nudgeVolume,
                          ),

                      const SizedBox(height: 5),
                      SmpMarkerPanel(
                        markers: _markers,
                        onAdd: _addMarker,
                        onJumpIndex: _jumpToMarkerIndex,
                        onEdit: _editMarker,
                        onDelete: _deleteMarker,
                        onJumpPrev: () =>
                            _jumpPrevNextMarker(next: false),
                        onJumpNext: () =>
                            _jumpPrevNextMarker(next: true),
                        fmt: _fmt,
                        onReorder: _onMarkerReorder,
                      ),
                      const SizedBox(height: 6),
                      const Text('마커 점프: Alt+1..9'),
                      const SizedBox(height: 12),
                      SmpNotesPanel(
                        controller: _notesCtl,
                        onChanged: (v) {
                          if (_notesInitApplying) return;
                          _notes = v;
                          _requestSave(saveMemo: true);
                          LessonMemoSync.instance.pushLocal(v);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              // 🔸 실제 오버레이는 "영상 파일 + 컨트롤러 존재" 둘 다 만족할 때만
              if (isVideoFile && hasVideoController)
                StickyVideoOverlay(
                  controller: videoController!,
                  scrollController: _scrollCtl,
                  viewportSize: Size(viewportW, viewportH),
                ),
            ],
          );
        },
      ),
    ),
  ),
);


}

Duration _computeStartCueFromLoopOrPos(Duration fallbackPos) {
    Duration candidate = fallbackPos;

    if (_loopA != null && _loopB != null) {
      candidate = _loopA! <= _loopB! ? _loopA! : _loopB!;
    } else if (_loopA != null) {
      candidate = _loopA!;
    } else if (_loopB != null) {
      candidate = _loopB!;
    }

    return _normalizeStartCueForLoop(candidate);
  }


    /// 주어진 인덱스의 패턴 스텝을 적용한다.
  /// - resetCounter=true  : 새 스텝으로 진입(ENTER) / 다이얼로그에서 처음 시작
  /// - resetCounter=false : 재생 리싱크(RESYNC_ON_PLAY) 용도, 남은 횟수는 유지
void _applyLoopPatternStepSync(
    int index, {
    required bool resetCounter,
    String logTag = 'APPLY',
  }) {
    if (_loopPatternSteps.isEmpty) return;

    final clampedIndex = index.clamp(0, _loopPatternSteps.length - 1);
    final step = _loopPatternSteps[clampedIndex];

    _loopPatternBaseSpeed ??= _speed;

    setState(() {
      _loopPatternActive = true;
      _loopPatternIndex = clampedIndex;

      if (resetCounter) {
        // ✅ 새 스텝 진입/다이얼로그 적용일 때만 카운터 리셋
        _loopPatternStepRemaining = step.repeats;
      }
      // resetCounter == false → 카운터는 건드리지 않고 유지

      _loopRemaining = _loopPatternStepRemaining;
    });

    final tempo = step.tempo.clamp(0.5, 1.5);
    if (_speed != tempo) {
      setState(() => _speed = tempo);
      unawaited(EngineApi.instance.setTempo(tempo));
    }

    _loopExec.setLoopEnabled(true);
    _loopExec.setRepeat(1);

    _logSoTScreen(
      'LOOP_PATTERN_$logTag idx=$clampedIndex tempo=${(tempo * 100).round()} repeat=${step.repeats}',
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }

  /// 재생 시점에 현재 스텝 설정만 다시 맞추는 용도.
  /// 남은 반복 횟수는 그대로 유지한다.
  void _resyncLoopPatternOnPlay() {
    if (!_loopPatternActive || _loopPatternSteps.isEmpty) return;

    _applyLoopPatternStepSync(
      _loopPatternIndex,
      resetCounter: false, // 🔑 카운터 유지
      logTag: 'RESYNC_ON_PLAY',
    );
  }


  void _loopToggleMain(bool on) {
    // 패턴 모드 + 루프 OFF → ON으로 전환하는 순간,
    // 현재 스텝(또는 0번 스텝)을 먼저 적용
    if (on && !_loopEnabled && _loopPatternSteps.isNotEmpty) {
      final safeIndex = _loopPatternIndex.clamp(
        0,
        _loopPatternSteps.length - 1,
      );
      _applyLoopPatternStepSync(
        safeIndex,
        resetCounter: true,
        logTag: 'TOGGLE_ON',
      );
    }

    _loopExec.setLoopEnabled(on);
    final newOn = _loopExec.loopOn;

    setState(() {
      _loopEnabled = newOn;
      _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    });

    // 루프 자체를 끄면, 패턴도 함께 종료 + 템포 복구
    if (!newOn && (_loopPatternActive || _loopPatternSteps.isNotEmpty)) {
      _resetLoopPattern(restoreTempo: true, clearSteps: false);
    }

    _requestSave();

    _logSoTScreen(
      'LOOP_TOGGLE on=$newOn pattern=${_loopPatternActive && _loopPatternSteps.isNotEmpty}',
    );

    // 🔥 최종 상태 정리
    _reconcileLoopAndPattern('LOOP_TOGGLE');
  }

  void _loopSetA(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    setState(() {
      _loopA = clamped;
      _loopB = null;
      _loopEnabled = false;
      _startCue = _normalizeStartCueForLoop(clamped);
    });

    _loopExec.setA(clamped);
    _loopExec.setLoopEnabled(false);

    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);
    _wf.setStartCue(_startCue);

    _requestSave();
    _logSoTScreen('LOOP_SET_A_KEY', loopA: _loopA, startCue: _startCue);

    // 🔥 최종 상태 정리
    _reconcileLoopAndPattern('LOOP_SET_A_KEY');
  }


  void _loopSetB(Duration pos) {
    final dur = _effectiveDuration;
    final clamped = dur > Duration.zero ? _clamp(pos, Duration.zero, dur) : pos;

    if (_loopA == null) {
      _logSoTScreen('LOOP_SET_B_KEY_WITHOUT_A → treat as new A', pos: clamped);
      _loopSetA(clamped);
      return;
    }

    Duration a = _loopA!;
    Duration b = clamped;

    if (b < a) {
      final tmp = a;
      a = b;
      b = tmp;
    }

    const minSpan = Duration(milliseconds: 80);

    if (dur > Duration.zero) {
      final span = b - a;

      if (span <= Duration.zero || span < minSpan) {
        final forwardEnd = a + minSpan;

        if (forwardEnd <= dur) {
          b = forwardEnd;
        } else {
          final safeA = dur > minSpan ? dur - minSpan : Duration.zero;
          a = safeA;
          b = dur;
        }
      }
    }

    _onLoopSetFromPanel(a, b);

    _logSoTScreen('LOOP_SET_B_KEY', loopA: a, loopB: b, startCue: _startCue);
    // _onLoopSetFromPanel 안에서 이미 _reconcileLoopAndPattern 호출됨
  }


  Future<void> _loopSetRepeat(int v) async {
    _loopExec.setRepeat(v);

    setState(() {
      _loopRepeat = _loopExec.repeat;
      _loopRemaining = _loopExec.remaining;
    });

    _wf.loopRepeat.value = _loopRepeat;

    if (_loopPatternActive || _loopPatternSteps.isNotEmpty) {
      _resetLoopPattern(restoreTempo: true, clearSteps: false);
    }

    _requestSave();

    _logSoTScreen(
      'LOOP_REPEAT_SET repeat=$_loopRepeat remaining=$_loopRemaining',
    );

    // 🔥 최종 상태 정리
    _reconcileLoopAndPattern('LOOP_REPEAT_SET');
  }

void _loopRepeatDelta(int delta) {
_loopSetRepeat(_loopRepeat + delta);
}

/// 패턴 실행을 위해 최소한의 루프 구간을 보장.
  /// - A/B가 유효하면 그대로 사용
  /// - 아니라면 StartCue ~ 트랙 끝까지를 임시 루프 구간으로 구성
  void _ensurePatternLoopRegion() {
    final dur = _effectiveDuration;
    if (dur <= Duration.zero) return;

    // 이미 유효한 A–B 루프가 있으면 그대로 사용
    if (_loopA != null &&
        _loopB != null &&
        _loopA! < _loopB! &&
        _loopA! >= Duration.zero &&
        _loopB! <= dur) {
      return;
    }

    // 🔹 스타트큐 기준으로 임시 루프 구간 구성
    final a = _normalizeStartCueForLoop(_startCue);
    final b = dur;

    setState(() {
      _loopA = a;
      _loopB = b;
      _loopEnabled = true;
    });

    _loopExec.setA(a);
    _loopExec.setB(b);
    _loopExec.setLoopEnabled(true);

    _wf.setLoop(a: _loopA, b: _loopB, on: _loopEnabled);

    _logSoTScreen(
      'LOOP_PATTERN_AUTO_RANGE a=${a.inMilliseconds}ms b=${b.inMilliseconds}ms',
      startCue: _startCue,
      loopA: _loopA,
      loopB: _loopB,
    );
  }


/// 루프 반복 설정/패턴 편집 다이얼로그
///
/// - 기존 숫자 입력 다이얼로그를 교체
/// - 패턴 예: 80% ×4회 → 90% ×4회 → 100% ×4회
/// - "패턴 해제" 선택 시 패턴 비활성화 + 기존 단일 반복 모드 유지
  Future<void> _loopPromptRepeat() async {
    final existing = _loopPatternSteps;

    final tempoCtrls = <TextEditingController>[];
    final repeatCtrls = <TextEditingController>[];

    void addRow({int? tempoPercent, int? repeats}) {
      tempoCtrls.add(
        TextEditingController(text: (tempoPercent ?? 100).toString()),
      );
      repeatCtrls.add(TextEditingController(text: (repeats ?? 4).toString()));
    }

    if (existing.isNotEmpty) {
      for (final step in existing) {
        final tp = (step.tempo * 100).round();
        addRow(tempoPercent: tp, repeats: step.repeats);
      }
    } else {
      addRow(tempoPercent: 100, repeats: 1);
    }

    final result = await showDialog<List<_LoopPatternStep>>(
      context: context,
      builder: (ctx) {
    return StatefulBuilder(
      builder: (ctx, setState) {
        Widget buildRow(int idx) {
          return Row(
            children: [
              SizedBox(
                width: 80,
                child: TextField(
                  controller: tempoCtrls[idx],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '템포(%)',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: repeatCtrls[idx],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '횟수',
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: '행 삭제',
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    tempoCtrls.removeAt(idx);
                    repeatCtrls.removeAt(idx);
                  });
                },
              ),
            ],
          );
        }

        return AlertDialog(
          title: const Text('루프 패턴 편집'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '예: 80% ×4회 → 90% ×4회 → 100% ×4회',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < tempoCtrls.length; i++) ...[
                  buildRow(i),
                  const SizedBox(height: 6),
                ],
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      final lastTempo = tempoCtrls.isNotEmpty
                          ? int.tryParse(
                                  tempoCtrls.last.text.trim()) ??
                              (_speed * 100).round()
                          : (_speed * 100).round();
                      addRow(
                        tempoPercent: lastTempo,
                        repeats: 4,
                      );
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('행 추가'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () {
                // 패턴 완전 해제
                Navigator.pop(ctx, <_LoopPatternStep>[]);
              },
              child: const Text('패턴 해제'),
            ),
            FilledButton(
              onPressed: () {
                final steps = <_LoopPatternStep>[];
                for (var i = 0; i < tempoCtrls.length; i++) {
                  final tp =
                      int.tryParse(tempoCtrls[i].text.trim()) ?? 0;
                  final rp =
                      int.tryParse(repeatCtrls[i].text.trim()) ?? 0;
                  if (tp <= 0 || rp <= 0) continue;

                  final tempoFactor =
                      (tp / 100.0).clamp(0.5, 1.5).toDouble();
                  final repeats = rp.clamp(1, 200);
                  steps.add(
                    _LoopPatternStep(
                      tempo: tempoFactor,
                      repeats: repeats,
                    ),
                  );
                }
                Navigator.pop(ctx, steps);
              },
              child: const Text('적용'),
            ),
          ],
        );
      },
    );
  },
);

    if (result == null) {
      // 취소
      return;
    }

    if (result.isEmpty) {
      // 🔁 [패턴 해제] 버튼:
      //  - 지금 "패턴 실행" 상태만 Off
      //  - 템포/스텝 정의/루프 반복값은 그대로 유지
      _disableLoopPatternOnly();
      _logSoTScreen('LOOP_PATTERN_DIALOG_OFF (steps kept)');

      _requestSave();
      _reconcileLoopAndPattern('LOOP_PATTERN_DIALOG_OFF');
      return;
    }

    // 🔹 실제 패턴 적용
    setState(() {
      _loopPatternBaseSpeed = _speed;
      _loopPatternSteps = result;
      _loopPatternActive = true;
      _loopPatternIndex = 0;
      _loopPatternStepRemaining = 0;
    });

    // 🔹 패턴 실행을 위해 루프 구간 보장
    _ensurePatternLoopRegion();

    // 0번 스텝부터 적용
    _applyLoopPatternStepSync(0, resetCounter: true);

    _logSoTScreen(
      'LOOP_PATTERN_UPDATED active=$_loopPatternActive steps=${_loopPatternSteps.length}',
    );

    _requestSave();
    _reconcileLoopAndPattern('LOOP_PATTERN_UPDATED');
  }

Future<void> _setSpeed(double v) async {
setState(() => _speed = v.clamp(0.5, 1.5));
await EngineApi.instance.setTempo(_speed);
_requestSave();
}

Future<void> _nudgeSpeed(int deltaPercent) async {
final step = deltaPercent / 100.0;
await _setSpeed(_speed + step);
}

Future<void> _pitchDelta(int d) async {
setState(() {
_pitchSemi = (_pitchSemi + d).clamp(-7, 7);
});
await EngineApi.instance.setPitch(_pitchSemi);
_requestSave();
}

Future<void> _setPitch(int semis) async {
setState(() => _pitchSemi = semis.clamp(-7, 7));
await EngineApi.instance.setPitch(_pitchSemi);
_requestSave();
}

Future<void> _setVolume(int v) async {
setState(() => _volume = v.clamp(0, 150));
await EngineApi.instance.setVolume(_volume / 100.0);
_requestSave();
}

Future<void> _nudgeVolume(int delta) async {
await _setVolume(_volume + delta);
}

void _logSoTScreen(
String label, {
Duration? pos,
Duration? startCue,
Duration? loopA,
Duration? loopB,
}) {
final effDur = _effectiveDuration;
final buf = StringBuffer('[SMP/Screen] $label');


if (pos != null) {
  buf.write(' pos=${pos.inMilliseconds}ms');
}
if (startCue != null) {
  buf.write(' sc=${startCue.inMilliseconds}ms');
}
if (loopA != null || loopB != null) {
  buf.write(
    ' loopA=${loopA?.inMilliseconds}ms, loopB=${loopB?.inMilliseconds}ms',
  );
}
if (effDur > Duration.zero) {
  buf.write(' dur=${effDur.inMilliseconds}ms');
}

debugPrint(buf.toString());


}

String _fmt(Duration d) {
if (d < Duration.zero) d = Duration.zero;
final totalSeconds = d.inMilliseconds ~/ 1000;
final minutes = totalSeconds ~/ 60;
final seconds = totalSeconds % 60;


return '${minutes.toString().padLeft(2, '0')}:'
    '${seconds.toString().padLeft(2, '0')}';


}

void _addMarker() {
final idx = _markers.length + 1;
final label = _lettersForIndex(idx);
final pos = _wf.position.value;

final m = MarkerPoint(pos, label);
_markers.add(m);
_syncMarkersToWaveform();
_requestSave();

debugPrint('[SMP-MARKER] ADD idx=$idx label=$label t=${_fmt(pos)}');
_logSoTScreen('MARKER_ADD idx=$idx', pos: pos);


}

/// WaveformPanel 쪽에서 마커 시간(time)이 변경되었을 때 진입하는 콜백
///
/// - 여기서는 "시간(t)"만 WaveformController → Screen 방향으로 받아오고
///   실제 진실 상태(_markers)는 항상 Screen이 소유한다.
/// - 길이(개수)가 같다는 전제: 마커 추가/삭제는 Screen(UI)에서만 한다.
void _onMarkersChangedFromWaveform(List<WfMarker> wfMarkers) {
if (_isDisposing) return;
if (_suppressWaveformMarkerEvents) {
// 우리가 _syncMarkersToWaveform()로 밀어 넣은 변경이면 무시
return;
}


// 개수가 다르면 (예외적 상황) 그냥 무시: 마커 추가/삭제는 Screen에서만 처리
if (wfMarkers.length != _markers.length) {
  _logSoTScreen(
    'WF_MARKERS_CHANGED_LEN_MISMATCH '
    '(wf=${wfMarkers.length}, screen=${_markers.length})',
  );
  return;
}

setState(() {
  // 1) 인덱스 기준으로 time만 반영
  for (int i = 0; i < wfMarkers.length; i++) {
    final w = wfMarkers[i];
    final m = _markers[i];

    // 시간만 Waveform → Screen으로 동기화
    m.t = w.time;
    // label / color 등은 Screen 쪽 정책(_relabelMarkersByTime)으로 관리
  }

  // 2) 타임라인 기준 자동 라벨링
  //
  //    - SongForm / 커스텀 텍스트 라벨은 유지
  //    - 자동 레터(A,B,C...) / 빈 라벨만 A,B,C... 재부여
  //    - B가 C 뒤로 넘어가면 "앞쪽 = B, 뒤쪽 = C"가 되도록 정렬
  _relabelMarkersByTime();
});

// 3) 정규화된 Screen 상태를 다시 WaveformController로 밀어 넣기
_syncMarkersToWaveform();

// 4) 사이드카 저장
_requestSave(saveMemo: false);

_logSoTScreen(
  'WF_MARKERS_CHANGED_SYNCED',
  pos: _position,
);


}

Future<void> _editMarker(int index) async {
if (index < 0 || index >= _markers.length) return;
final m = _markers[index];


final initialLabel = (m.label == null || m.label!.isEmpty)
    ? _lettersForIndex(index + 1)
    : m.label!;
final textController = TextEditingController(text: initialLabel);

String? selectedSongForm;
if (_isSongFormLabel(m.label)) {
  // 기존에 Song Form 라벨이면 선택 상태로 시작
  selectedSongForm = _markerSongFormLabels.firstWhere(
    (s) => s.toLowerCase() == m.label!.trim().toLowerCase(),
  );
}

final newLabel = await showDialog<String>(
  context: context,
  builder: (ctx) {
    return StatefulBuilder(
      builder: (ctx, setState) {
        void selectSongForm(String label) {
          setState(() {
            selectedSongForm = label;
            textController.text = label;
            textController.selection = TextSelection.fromPosition(
              TextPosition(offset: textController.text.length),
            );
          });
        }

        return AlertDialog(
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Song Form',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int rowStart = 0;
                          rowStart < _markerSongFormLabels.length;
                          rowStart += 4)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: (rowStart + 4 <
                                    _markerSongFormLabels.length)
                                ? 6
                                : 0,
                          ),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final label in _markerSongFormLabels
                                  .skip(rowStart)
                                  .take(4))
                                ChoiceChip(
                                  label: Text(label),
                                  selected: selectedSongForm == label,
                                  onSelected: (sel) {
                                    if (!sel) return;
                                    selectSongForm(label);
                                  },
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: textController,
                    decoration: const InputDecoration(
                      labelText: '마커 라벨',
                      hintText: 'A, Verse, Solo 등 입력',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final txt = textController.text.trim();
                Navigator.pop(ctx, txt);
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
  },
);

if (newLabel == null) return; // 취소

setState(() {
  final trimmed = newLabel.trim();
  if (trimmed.isEmpty) {
    // 비워두면 자동 A,B,C 모드로 두기
    // 👉 이제는 null 대신 빈 문자열로 관리
    m.label = '';
  } else {
    m.label = trimmed;
  }

  // 편집 후에도 타임라인 기준으로 정렬 + 자동 라벨 재배치
  _relabelMarkersByTime();
});

// WaveformController에 반영
_syncMarkersToWaveform();
_requestSave(saveMemo: false);


}

Future<void> _jumpToMarkerIndex(int index) async {
if (index < 0 || index >= _markers.length) return;
final m = _markers[index];


// 1) 목표 지점 (클램프)
final rawTarget = m.t;
final target = _normalizeMarkerTarget(rawTarget);

final isPlaying = EngineApi.instance.isPlaying;

setState(() {
  // 🔹 정지 상태 + 루프 OFF일 때는
  //    "이 마커가 현재 연습 포인트"가 되도록 StartCue를 같이 맞춰준다.
  if (!isPlaying && !_loopEnabled) {
    _startCue = _normalizeStartCueForLoop(target);
    _wf.setStartCue(_startCue);
  }

  // 🔹 루프 켜져 있는데 점프 지점이 루프 밖이면 → 루프 OFF
  if (_loopA != null && _loopB != null) {
    final a = _loopA!;
    final b = _loopB!;
    if (a < b && (target < a || target > b)) {
      _loopEnabled = false;
      _loopExec.setLoopEnabled(false);
      _wf.setLoop(a: _loopA, b: _loopB, on: false);
    }
  }

  // 🔹 마커 네비게이션 커서도 최신 위치로 업데이트
  _markerNavCursor = target;
});

// 2) 엔진 시킹 (정지/재생 상태에 따라 resume 여부 자동 결정)
await _engineSeekAndMaybeResumeFromScreen(target);

// 3) 위치만 저장
_requestSave(saveMemo: false);

_logSoTScreen('MARKER_JUMP idx=$index', pos: target, startCue: _startCue);


}

Future<void> _jumpPrevNextMarker({required bool next}) async {
if (_markers.isEmpty) return;


// 🔹 기준 위치: 마커 네비게이션 커서가 있으면 그걸 우선 사용
//    - Alt+←/→를 연속 입력할 때, "시간이 조금 흘렀다"는 이유로
//      같은 마커에 계속 머무는 현상을 줄이기 위함.
final base = _markerNavCursor ?? _position;

// 시간 순으로 정렬된 리스트 기준으로 이전/다음 후보 탐색
final sorted = [..._markers]..sort((a, b) => a.t.compareTo(b.t));

MarkerPoint? candidate;
if (next) {
  for (final m in sorted) {
    if (m.t > base) {
      candidate = m;
      break;
    }
  }
  candidate ??= sorted.first; // 끝에서 더 가면 처음으로 래핑
} else {
  for (final m in sorted.reversed) {
    if (m.t < base) {
      candidate = m;
      break;
    }
  }
  candidate ??= sorted.last; // 처음에서 더 가면 끝으로 래핑
}

final rawTarget = candidate.t;
final target = _normalizeMarkerTarget(rawTarget);
final isPlaying = EngineApi.instance.isPlaying;

setState(() {
  // 🔹 정지 상태 + 루프 OFF일 때는
  //    "이 마커가 현재 연습 포인트"가 되도록 StartCue를 같이 맞춰준다.
  if (!isPlaying && !_loopEnabled) {
    _startCue = _normalizeStartCueForLoop(target);
    _wf.setStartCue(_startCue);
  }

  // 🔹 루프 켜져 있고, 점프 지점이 루프 밖이면 → 루프 OFF
  if (_loopA != null && _loopB != null) {
    final a = _loopA!;
    final b = _loopB!;
    if (a < b && (target < a || target > b)) {
      _loopEnabled = false;
      _loopExec.setLoopEnabled(false);
      _wf.setLoop(a: _loopA, b: _loopB, on: false);
    }
  }

  // 🔹 네비게이션 커서 업데이트 (다음 Alt+←/→의 기준이 됨)
  _markerNavCursor = target;
});

// 재생 위치만 이동
await _engineSeekAndMaybeResumeFromScreen(target);
_requestSave(saveMemo: false);

_logSoTScreen(
  next ? 'MARKER_NEXT' : 'MARKER_PREV',
  pos: target,
  startCue: _startCue,
);


}

void _reorderMarker(int oldIndex, int newIndex) {
if (oldIndex < 0 || oldIndex >= _markers.length) return;

if (newIndex < 0) newIndex = 0;
if (newIndex >= _markers.length) {
  newIndex = _markers.length - 1;
}

setState(() {
  final item = _markers.removeAt(oldIndex);
  _markers.insert(newIndex, item);

  // 🔹 패널 순서를 기준으로 자동 A,B,C 라벨 재정렬
  _relabelMarkersByListOrder();

  // 🔹 WaveformController에도 라벨/색/시간을 그대로 반영
  _syncMarkersToWaveform();
});

_requestSave();
_logSoTScreen('MARKER_REORDER old=$oldIndex new=$newIndex');


}

void _deleteMarker(int index) {
if (index < 0 || index >= _markers.length) return;
final removed = _markers[index];

setState(() => _markers.removeAt(index));
_syncMarkersToWaveform();

_requestSave();

debugPrint(
  '[SMP-MARKER] DELETE idx=$index label="${removed.label}" t=${_fmt(removed.t)}',
);
_logSoTScreen('MARKER_DELETE idx=$index', pos: removed.t);

}

Duration _normalizeStartCueForLoop(Duration candidate) {
final dur = _effectiveDuration;

Duration sc = candidate;
if (dur > Duration.zero) {
  sc = _clamp(sc, Duration.zero, dur);
} else if (sc < Duration.zero) {
  sc = Duration.zero;
}

if (_loopA == null || _loopB == null) {
  return sc;
}

final a = _loopA!;
final b = _loopB!;

if (dur <= Duration.zero || a >= b) {
  return sc;
}

final aClamped = _clamp(a, Duration.zero, dur);
final bClamped = _clamp(b, Duration.zero, dur);

if (sc < aClamped || sc > bClamped) {
  return aClamped;
}

return sc;

}

// 🔹 마커 점프 시 사용할 시킹 타겟 정규화 (0 ~ duration 안으로만 클램프)
Duration _normalizeMarkerTarget(Duration candidate) {
final dur = _effectiveDuration;


Duration t = candidate;

if (dur > Duration.zero) {
  t = _clamp(t, Duration.zero, dur);
} else if (t < Duration.zero) {
  t = Duration.zero;
}

// 🔥 마커 점프는 단순히 재생 위치만 이동한다.
// 루프 안/밖 여부, StartCue 재설정 여부는 호출부에서 별도로 처리한다.
return t;


}
}
