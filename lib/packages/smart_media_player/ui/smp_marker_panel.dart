// lib/packages/smart_media_player/ui/smp_marker_panel.dart

import 'package:flutter/material.dart';
import '../../../ui/components/app_controls.dart';
import '../models/marker_point.dart';

class SmpMarkerPanel extends StatelessWidget {
  final List<MarkerPoint> markers;
  final VoidCallback onAdd;
  final void Function(int index1based) onJumpIndex;
  final void Function(int index) onEdit;
  final void Function(int index) onDelete;
  final VoidCallback onJumpPrev;
  final VoidCallback onJumpNext;

  /// 시간 포맷터 (StartCue/Transport와 동일 포맷 쓰기 위함)
  final String Function(Duration)? fmt;

  /// 마커 순서 변경 콜백 (oldIndex → newIndex)
  final void Function(int oldIndex, int newIndex)? onReorder;

  static const List<Color> _presetColors = [
    Colors.red,
    Colors.blue,
    Colors.amber,
    Colors.green,
  ];

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

  Color _colorForIndex(int index, MarkerPoint m) {
    if (m.color != null) return m.color!;
    if (_presetColors.isEmpty) return Colors.red;
    return _presetColors[index % _presetColors.length];
  }

  String? _buildTooltip(MarkerPoint m) {
    if (fmt == null) return null;
    final label = m.label;
    final labelPart = (label != null && label.isNotEmpty) ? '[$label] ' : '';
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
                              onJump: () => onJumpIndex(i + 1),
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
                    itemBuilder: (ctx, index) {
                      final m = markers[index];
                      return Padding(
                        key: ValueKey(
                          'marker_${index}_${m.label}_${m.t.inMilliseconds}',
                        ),
                        padding: const EdgeInsets.only(right: 6),
                        child: _MarkerChip(
                          label: m.label,
                          color: _colorForIndex(index, m),
                          tooltip: _buildTooltip(m),
                          onJump: () => onJumpIndex(index + 1),
                          onEdit: () => onEdit(index),
                          onDelete: () => onDelete(index),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      constraints: const BoxConstraints(minHeight: 30, minWidth: 48),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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

    return GestureDetector(
      onTap: onJump,
      onLongPress: onEdit,
      onSecondaryTap: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('마커 삭제'),
            content: Text('[$_displayLabel] 마커를 삭제할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        );

        if (ok == true) onDelete();
      },
      child: MouseRegion(cursor: SystemMouseCursors.click, child: chipBody),
    );
  }
}
