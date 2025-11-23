// lib/packages/smart_media_player/ui/smp_control_panel.dart
import 'package:flutter/material.dart';
import '../../../ui/components/app_controls.dart'; // AppSection, PresetSquare 등

class SmpControlPanel extends StatelessWidget {
  final double speed; // 0.5 ~ 1.5
  final int pitchSemi; // -7 ~ +7
  final int volume; // 0 ~ 150

  final void Function(double v) onSpeedChanged;
  final void Function(int deltaPercent) onSpeedNudged;

  final void Function(int newSemis) onPitchSet;
  final void Function(int delta) onPitchNudged;

  final void Function(int newVolume) onVolumeSet;
  final void Function(int delta) onVolumeNudged;

  const SmpControlPanel({
    super.key,
    required this.speed,
    required this.pitchSemi,
    required this.volume,
    required this.onSpeedChanged,
    required this.onSpeedNudged,
    required this.onPitchSet,
    required this.onPitchNudged,
    required this.onVolumeSet,
    required this.onVolumeNudged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      fontWeight: FontWeight.w700,
    );
    final valueStyle = theme.textTheme.labelLarge!;

    const presets = <double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0];

    final accent = const Color(0xFF81D4FA);
    final inactive = accent.withValues(alpha: 0.25);

    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      activeTrackColor: accent,
      inactiveTrackColor: inactive,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.08),
    );

    Widget row(String label, String value, {Widget? trailing}) => SizedBox(
      height: 26,
      child: Row(
        children: [
          Text(label, style: labelStyle),
          const SizedBox(width: 6),
          Text(value, style: valueStyle),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(child: trailing),
          ],
        ],
      ),
    );

    Widget presetStrip(double cur) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final v in presets) ...[
            PresetSquare(
              label: '${(v * 100).round()}',
              active: (v - cur).abs() < 0.011,
              onTap: () => onSpeedChanged(v),
              size: 32,
              height: 22,
              fontSize: 10,
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
    );

    return AppSection(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ==== SPEED ====
          Expanded(
            flex: 7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row(
                  '템포',
                  '${(speed * 100).round()}%',
                  trailing: presetStrip(speed),
                ),
                const SizedBox(height: 2),
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '템포 -5%',
                        onPressed: () => onSpeedNudged(-5),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: speed,
                          min: 0.5,
                          max: 1.5,
                          divisions: 100,
                          onChanged: (v) => onSpeedChanged(v),
                        ),
                      ),
                      IconButton(
                        tooltip: '템포 +5%',
                        onPressed: () => onSpeedNudged(5),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // ==== PITCH ====
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('키', '${pitchSemi >= 0 ? '+' : ''}$pitchSemi'),
                const SizedBox(height: 2),
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '-1 key',
                        onPressed: () => onPitchNudged(-1),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: pitchSemi.toDouble(),
                          min: -7,
                          max: 7,
                          divisions: 14,
                          onChanged: (v) => onPitchSet(v.round()),
                        ),
                      ),
                      IconButton(
                        tooltip: '+1 key',
                        onPressed: () => onPitchNudged(1),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // ==== VOLUME ====
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('볼륨', '$volume%'),
                const SizedBox(height: 2),
                SliderTheme(
                  data: sliderTheme,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '볼륨 -5%',
                        onPressed: () => onVolumeNudged(-5),
                        icon: const Icon(Icons.remove),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: volume.toDouble(),
                          min: 0,
                          max: 150,
                          divisions: 150,
                          onChanged: (v) => onVolumeSet(v.round()),
                        ),
                      ),
                      IconButton(
                        tooltip: '볼륨 +5%',
                        onPressed: () => onVolumeNudged(5),
                        icon: const Icon(Icons.add),
                        visualDensity: const VisualDensity(
                          horizontal: -4,
                          vertical: -4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
