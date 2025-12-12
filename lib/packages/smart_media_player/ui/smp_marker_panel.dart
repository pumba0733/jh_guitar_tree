// lib/packages/smart_media_player/ui/smp_marker_panel.dart

import 'package:flutter/material.dart';
import '../../../ui/components/app_controls.dart';
import '../models/marker_point.dart';

class SmpMarkerPanel extends StatelessWidget {
  final List<MarkerPoint> markers;
  final VoidCallback onAdd;
  final void Function(int index) onJumpIndex;
  final void Function(int index) onEdit;
  final void Function(int index) onDelete;
  final VoidCallback onJumpPrev;
  final VoidCallback onJumpNext;

  /// 시간 포맷터 (StartCue/Transport와 동일 포맷 쓰기 위함)
  final String Function(Duration)? fmt;

  /// 마커 순서 변경 콜백 (oldIndex → newIndex)
  final void Function(int oldIndex, int newIndex)? onReorder;

  // 인덱스 기반 기본 컬러 프리셋
  static const List<Color> _presetColors = [
    Colors.red,
    Colors.blue,
    Colors.amber,
    Colors.green,
  ];

  // 텍스트 입력 마커 공통 컬러
  static const Color _customTextColor = Colors.deepPurple;

  // Song Form 프리셋 라벨 목록
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

  // Song Form 라벨별 고정 컬러
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

  const SmpMarkerPanel({
    super.key,
    required this.markers,
    required this.onAdd,
    required this.onJumpIndex,
    required this.onEdit,
    required this.onDelete,
    required this.onJumpPrev,
    required this.onJumpNext,
    this.fmt,
    this.onReorder,
  });

  bool _isAutoLetterLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.length != 1) return false;
    final code = trimmed.codeUnitAt(0);
    return code >= 65 && code <= 90; // 'A'..'Z'
  }

  /// Song Form 라벨인지 확인 후, 일치하는 프리셋 라벨을 반환
  String? _matchSongFormLabel(String label) {
    final l = label.trim().toLowerCase();
    if (l.isEmpty) return null;

    for (final preset in _songFormLabels) {
      if (preset.toLowerCase() == l) return preset;
    }
    return null;
  }

  /// 마커용 컬러 결정 로직
  ///
  /// 우선순위:
  ///  1) MarkerPoint.color 가 있으면 그대로 사용
  ///  2) Song Form 라벨이면 Song Form 고정 컬러
  ///  3) 자동 레터(A,B,C...)면 인덱스 기반 프리셋 순환
  ///  4) 일반 텍스트 라벨이면 공통 텍스트 컬러
  ///  5) 라벨 비어 있으면 프리셋 순환
  Color _colorForIndex(int index, MarkerPoint m) {
    // 1) 명시적인 color가 있으면 우선
    if (m.color != null) return m.color!;

    // label이 null일 수도 있으니, 한 번 정리해서 사용
    final label = m.label ?? '';

    // 2) Song Form 라벨 매칭
    final matchedSongForm = _matchSongFormLabel(label);
    if (matchedSongForm != null) {
      return _songFormColors[matchedSongForm] ?? Colors.blueGrey;
    }

    // 3) 자동 레터(A,B,C...) → 인덱스 기반 프리셋
    if (_isAutoLetterLabel(label)) {
      if (_presetColors.isEmpty) return Colors.red;
      return _presetColors[index % _presetColors.length];
    }

    // 4) 일반 텍스트 라벨 (비어있지 않음) → 한 가지 컬러로 통일
    if (label.trim().isNotEmpty) {
      return _customTextColor;
    }

    // 5) 라벨 비어 있음 → 기본 프리셋
    if (_presetColors.isEmpty) return Colors.red;
    return _presetColors[index % _presetColors.length];
  }

  String? _buildTooltip(MarkerPoint m) {
    if (fmt == null) return null;

    final label = m.label ?? '';
    final labelPart = label.isNotEmpty ? '[$label] ' : '';

    return '$labelPart${fmt!(m.t)}';
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;

    return AppSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              "Markers",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),

          // === Prev / Next / Add ===
          Row(
            children: [
              AppMiniButton(
                icon: Icons.skip_previous,
                label: "Prev",
                compact: true,
                minSize: const Size(34, 30),
                iconSize: 18,
                fontSize: 12,
                onPressed: onJumpPrev,
              ),
              const SizedBox(width: 6),
              AppMiniButton(
                icon: Icons.skip_next,
                label: "Next",
                compact: true,
                minSize: const Size(34, 30),
                iconSize: 18,
                fontSize: 12,
                onPressed: onJumpNext,
              ),
              const SizedBox(width: 12),
              AppMiniButton(
                icon: Icons.add,
                label: "Add",
                compact: true,
                minSize: const Size(34, 30),
                iconSize: 18,
                fontSize: 12,
                onPressed: onAdd,
              ),
            ],
          ),

          const SizedBox(height: 8),

          // === Marker List (scroll / reorder) ===
          SizedBox(
            height: 40,
            child: (onReorder == null || markers.length <= 1)
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: [
                        for (int i = 0; i < markers.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _MarkerChip(
                              label: markers[i].label,
                              color: _colorForIndex(i, markers[i]),
                              tooltip: _buildTooltip(markers[i]),
                              onJump: () => onJumpIndex(i),
                              onEdit: () => onEdit(i),
                              onDelete: () => onDelete(i),
                            ),
                          ),
                      ],
                    ),
                  )
                                : ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: markers.length,
                    onReorder: onReorder!,
                    // 🔹 기본 드래그 핸들 비활성화 → 겹치는 아이콘 제거
                    buildDefaultDragHandles: false,
                    itemBuilder: (ctx, index) {
                      final m = markers[index];
                      return ReorderableDragStartListener(
                        key: ValueKey(
                          'marker_${index}_${m.label}_${m.t.inMilliseconds}',
                        ),
                        index: index,
                        // 칩 전체를 드래그 영역으로 사용
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _MarkerChip(
                            label: m.label,
                            color: _colorForIndex(index, m),
                            tooltip: _buildTooltip(m),
                            onJump: () => onJumpIndex(index),
                            onEdit: () => onEdit(index),
                            onDelete: () => onDelete(index),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          const SizedBox(height: 8),

          Row(
            children: [
              Icon(Icons.keyboard, size: 16, color: hint),
              const SizedBox(width: 6),
              Text(
                'Jump: Alt+1..9   •   Prev/Next: Alt+← / Alt+→',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MarkerChip extends StatelessWidget {
  final String? label;
  final Color? color;
  final String? tooltip;
  final VoidCallback onJump;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MarkerChip({
    required this.label,
    required this.onJump,
    required this.onEdit,
    required this.onDelete,
    this.color,
    this.tooltip,
  });

  String get _displayLabel => (label == null || label!.isEmpty) ? '마커' : label!;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;

    Widget chipBody = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      constraints: const BoxConstraints(minHeight: 30, minWidth: 64),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A, B, Verse ... 라벨
          Icon(Icons.flag, size: 14, color: c),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _displayLabel,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                color: c.withValues(alpha: 0.95),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // ✏️ 수정 아이콘
          SizedBox(
            width: 22,
            height: 22,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              tooltip: '마커 편집',
              onPressed: onEdit,
              icon: Icon(
                Icons.edit,
                size: 14,
                color: c.withValues(alpha: 0.95),
              ),
            ),
          ),

          const SizedBox(width: 2),

          // 🗑 삭제 아이콘
          SizedBox(
            width: 22,
            height: 22,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              tooltip: '마커 삭제',
              onPressed: onDelete,
              icon: Icon(
                Icons.close,
                size: 14,
                color: c.withValues(alpha: 0.95),
              ),
            ),
          ),
        ],
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      chipBody = Tooltip(
        message: tooltip!,
        preferBelow: false,
        waitDuration: const Duration(milliseconds: 400),
        child: chipBody,
      );
    }

    // 칩 전체 클릭 시 점프, 아이콘은 개별 onPressed 사용
    return GestureDetector(
      onTap: onJump,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: chipBody),
    );
  }
}
