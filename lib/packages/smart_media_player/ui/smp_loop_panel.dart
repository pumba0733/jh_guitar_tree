// lib/packages/smart_media_player/ui/smp_loop_panel.dart

import 'package:flutter/material.dart';

// AppSection, AppMiniButton
import '../../../ui/components/app_controls.dart';

/// ===================================================================
///  UI-Only Loop Panel (TransportBar의 Loop 영역만 독립화)
///  - 단일 Compact 스타일(트랜스포트 바 내 한 줄 요약 전용)
/// ===================================================================
class SmpLoopPanel extends StatelessWidget {
  final Duration? loopA;
  final Duration? loopB;
  final bool loopEnabled;

  /// 총 반복 설정값 (0 = 무한)
  final int loopRepeat;

  /// 남은 반복 횟수
  /// - 0 이상이면 남은 횟수로 사용
  /// - 음수면 "아직 시작 전" 등의 상태로 보고 loopRepeat 기반으로 처리
  final int loopRemaining;

  /// 루프 패턴이 현재 활성 상태인지 여부
  final bool loopPatternActive;

  /// 현재 플레이어 재생 중 여부 (라벨용)
  final bool isPlaying;

  final VoidCallback onLoopASet;
  final VoidCallback onLoopBSet;

  final ValueChanged<bool> onLoopToggle;

  final VoidCallback onLoopRepeatMinus1;
  final VoidCallback onLoopRepeatPlus1;
  final VoidCallback onLoopRepeatLongMinus5;
  final VoidCallback onLoopRepeatLongPlus5;
  final VoidCallback onLoopRepeatPrompt;

  /// Duration → "mm:ss.S" 같은 표시용 포맷터
  final String Function(Duration) fmt;

  const SmpLoopPanel({
    super.key,
    required this.loopA,
    required this.loopB,
    required this.loopEnabled,
    required this.loopRepeat,
    required this.loopRemaining,
    required this.onLoopASet,
    required this.onLoopBSet,
    required this.onLoopToggle,
    required this.onLoopRepeatMinus1,
    required this.onLoopRepeatPlus1,
    required this.onLoopRepeatLongMinus5,
    required this.onLoopRepeatLongPlus5,
    required this.onLoopRepeatPrompt,
    required this.fmt,
    required this.loopPatternActive,
    required this.isPlaying,
  });


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const w6 = SizedBox(width: 6);

    // ---- 한 줄 상태 요약 라벨 생성 ----
        String _buildStatusLabel() {
      final hasSection = loopA != null && loopB != null;
      final infinite = loopRepeat == 0;
      final playing = isPlaying;

      // 🔹 패턴 모드일 때는 일반 "총 N회" 라벨을 쓰지 않고,
      //    훨씬 단순한 상태 문구만 사용한다.
      if (loopPatternActive) {
        if (!loopEnabled) {
          if (!hasSection) {
            return '루프 패턴 대기 중 · 구간 미설정';
          } else {
            return playing ? '루프 패턴 일시 정지됨' : '루프 패턴 대기 중';
          }
        }

        if (!hasSection) {
          return playing ? '루프 패턴 실행 중 (구간 미설정)' : '루프 패턴 대기 중 (구간 미설정)';
        }

        // 유효한 A–B 구간 + 루프 ON
        return playing ? '루프 패턴 실행 중' : '루프 패턴 대기 중';
      }

      // === 여기부터는 "일반 루프 모드" 라벨 ===

      // 남은 횟수 계산 (음수면 "아직 소모 전"으로 보고 loopRepeat와 동일하게 취급)
      final remain = loopRemaining >= 0 ? loopRemaining : loopRepeat;

      // 현재 진행 회차(대략적인 감각용) - "재생 중"일 때만 의미 있음
      int? currentRound;
      if (!infinite && loopRepeat > 0 && remain >= 0 && remain <= loopRepeat) {
        final used = (loopRepeat - remain).clamp(0, loopRepeat);
        currentRound = used + 1; // 1회차, 2회차...
      }

      // 1) 루프 꺼짐
      if (!loopEnabled) {
        if (!hasSection) {
          return '루프 꺼짐 · 구간 미설정';
        } else {
          return '루프 꺼짐 · A–B 구간만 설정됨';
        }
      }

      // 2) 루프 켜짐 + 구간 미설정
      if (!hasSection) {
        if (infinite) {
          return playing
              ? '루프 켬 · 구간 미설정(무한 반복 재생 중)'
              : '루프 켬 · 구간 미설정(무한 반복 대기 중)';
        } else {
          return playing
              ? '루프 켬 · 구간 미설정(총 $loopRepeat회 재생 중)'
              : '루프 켬 · 구간 미설정(총 $loopRepeat회 예정)';
        }
      }

      // 3) A–B 구간 설정 + 무한 반복
      if (infinite) {
        return playing ? 'A–B 구간 무한 반복 중' : 'A–B 구간 무한 반복 대기 중';
      }

      // 4) A–B 구간 설정 + 유한 반복
      //
      // 🔹 재생 중이 아닐 때는 "진행 중"이라는 표현을 절대 쓰지 않는다.
      if (!playing) {
        if (remain <= 0) {
          return 'A–B 반복 완료 (총 $loopRepeat회)';
        }
        if (remain == loopRepeat) {
          return 'A–B 반복 대기 중 (총 $loopRepeat회 예정)';
        }
        if (remain == 1) {
          return 'A–B 마지막 1회 반복 대기 중 (총 $loopRepeat회 중 1회 남음)';
        }
        return 'A–B 반복 일시정지 · 남은 $remain / 총 $loopRepeat회';
      }

      // 🔹 여기부터는 "재생 중"일 때만
      if (remain <= 0) {
        return 'A–B 반복 마무리 단계 (총 $loopRepeat회)';
      }

      if (remain == 1) {
        if (currentRound != null) {
          return 'A–B 마지막 1회 반복 중 (현재 ${currentRound}회차 / 총 $loopRepeat회)';
        }
        return 'A–B 마지막 1회 반복 중';
      }

      if (remain == loopRepeat) {
        // 아직 한 번도 소모되지 않은 상태
        return 'A–B 반복 시작 (총 $loopRepeat회 예정)';
      }

      // 진행 중: 남은 / 총 (+ 가능하면 현재 회차)
      if (currentRound != null) {
        return 'A–B 반복 진행 중 · 남은 $remain / 총 $loopRepeat회 (현재 ${currentRound}회차)';
      }

      return 'A–B 반복 진행 중 · 남은 $remain / 총 $loopRepeat회';
    }


        final statusLabel = _buildStatusLabel();

    final isPatternOn = loopPatternActive;
    final pillBg = isPatternOn
        ? theme.colorScheme.primary.withValues(alpha: 0.08)
        : Colors.transparent;
    final pillBorder = isPatternOn
        ? theme.colorScheme.primary.withValues(alpha: 0.9)
        : theme.dividerColor;
    final pillTextColor = isPatternOn
        ? theme.colorScheme.primary.withValues(alpha: 0.95)
        : theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8);

    final labelWithPattern = isPatternOn
        ? '$statusLabel  ·  패턴 ON'
        : statusLabel;


    return AppSection(
      // compact 스타일을 기본값으로 고정
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ---- Loop A ----
          AppMiniButton(
            compact: true,
            icon: Icons.playlist_add,
            label: loopA == null ? 'A 지점 설정' : 'A: ${fmt(loopA!)}',
            onPressed: onLoopASet,
          ),
          w6,

          // ---- Loop B ----
          AppMiniButton(
            compact: true,
            icon: Icons.playlist_add_check,
            label: loopB == null ? 'B 지점 설정' : 'B: ${fmt(loopB!)}',
            onPressed: onLoopBSet,
          ),

          const SizedBox(width: 10),

          // ---- Loop Switch ----
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '반복',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 6),
              Switch.adaptive(
                value: loopEnabled,
                onChanged: onLoopToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),

          const SizedBox(width: 12),

          // ---- 반복/패턴 상태 요약 블럭 (한 줄 요약) ----
                    Expanded(
            child: InkWell(
              onTap: onLoopRepeatPrompt,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: pillBg,
                  border: Border.all(color: pillBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isPatternOn ? Icons.auto_awesome : Icons.repeat,
                      size: 14,
                      color: pillTextColor,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        labelWithPattern,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: pillTextColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),


          // 🔹 RemainingPill는 compact 스타일과 충돌하므로 제거
          //    (남은/총 회수 정보는 statusLabel 안에서 표현)
        ],
      ),
    );
  }
}
