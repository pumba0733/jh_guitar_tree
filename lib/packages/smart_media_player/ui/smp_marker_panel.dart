//lib/packages/smart_media_player/ui/smp_marker_panel.dart


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

  const SmpMarkerPanel({
    super.key,
    required this.markers,
    required this.onAdd,
    required this.onJumpIndex,
    required this.onEdit,
    required this.onDelete,
    required this.onJumpPrev,
    required this.onJumpNext,
  });

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

          Row(
            children: [
              AppMiniButton(
                icon: Icons.skip_previous,
                label: "Prev",
                compact: true,
                minSize: const Size(30, 28),
                iconSize: 16,
                fontSize: 12,
                onPressed: onJumpPrev,
              ),
              const SizedBox(width: 6),
              AppMiniButton(
                icon: Icons.skip_next,
                label: "Next",
                compact: true,
                minSize: const Size(30, 28),
                iconSize: 16,
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

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < markers.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _MarkerChip(
                      label: markers[i].label,
                      color: markers[i].color,
                      onJump: () => onJumpIndex(i + 1),
                      onEdit: () => onEdit(i),
                      onDelete: () => onDelete(i),
                    ),
                  ),
              ],
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
  final String label;
  final Color? color;
  final VoidCallback onJump;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MarkerChip({
    required this.label,
    required this.onJump,
    required this.onEdit,
    required this.onDelete,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;

    return GestureDetector(
      onTap: onJump,
      onLongPress: onEdit,
      onSecondaryTap: onDelete,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c, width: 1),
        ),
        child: Row(
          children: [
            Icon(Icons.flag, size: 14, color: c),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: c,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
