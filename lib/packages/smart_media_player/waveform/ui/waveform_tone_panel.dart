// smart_media_player/waveform/ui/waveform_tone_panel.dart
// v3.24.0 | Tone Panel (Presets + Sliders + Toggles, Live repaint)

import 'package:flutter/material.dart';
import '../waveform_tuning.dart';

class WaveformTonePanel extends StatefulWidget {
  const WaveformTonePanel({super.key});
  @override
  State<WaveformTonePanel> createState() => _WaveformTonePanelState();
}

class _WaveformTonePanelState extends State<WaveformTonePanel> {
  final t = WaveformTuning.I;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    return Material(
      color: Theme.of(context).colorScheme.surface.withOpacity(0.04),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Waveform Tone',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                DropdownButton<WaveformPreset>(
                  value: WaveformPreset.transcribeLike,
                  items: const [
                    DropdownMenuItem(
                      value: WaveformPreset.transcribeLike,
                      child: Text('Transcribe-like'),
                    ),
                    DropdownMenuItem(
                      value: WaveformPreset.iosLike,
                      child: Text('iOS-like'),
                    ),
                    DropdownMenuItem(
                      value: WaveformPreset.cleanPath,
                      child: Text('Clean Path'),
                    ),
                    DropdownMenuItem(
                      value: WaveformPreset.solidBars,
                      child: Text('Solid Bars'),
                    ),
                    DropdownMenuItem(
                      value: WaveformPreset.ecgSigned,
                      child: Text('ECG (±)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) t.applyPreset(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),

            _numSlider(
              'dB Floor',
              -80,
              -20,
              t.dbFloor,
              (v) => t.dbFloor = v,
              suffix: ' dB',
            ),
            _numSlider(
              'dB Ceil',
              -12,
              -0.5,
              t.dbCeil,
              (v) => t.dbCeil = v,
              suffix: ' dB',
            ),
            _numSlider(
              'Gamma low',
              1.0,
              2.5,
              t.loudGammaLow,
              (v) => t.loudGammaLow = v,
            ),
            _numSlider(
              'Gamma high',
              1.0,
              2.0,
              t.loudGammaHigh,
              (v) => t.loudGammaHigh = v,
            ),

            const Divider(height: 16),
            _numSlider(
              'Stroke',
              0.8,
              3.0,
              t.strokeWidth,
              (v) => t.strokeWidth = v,
              suffix: ' px',
            ),
            _numSlider('Fill α', 0.0, 0.6, t.fillAlpha, (v) => t.fillAlpha = v),
            _numSlider('Blur σ', 0.0, 2.0, t.blurSigma, (v) => t.blurSigma = v),

            const Divider(height: 16),
            _numSlider(
              '± Visual',
              0.8,
              1.2,
              t.signedVisualScale,
              (v) => t.signedVisualScale = v,
            ),

            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                _toggle('Dual-Layer', t.dualLayer, (v) => t.dualLayer = v),
                _toggle(
                  'Stereo Split',
                  t.splitStereoQuadrants,
                  (v) => t.splitStereoQuadrants = v,
                ),
                _toggle(
                  'Signed (±)',
                  t.useSignedAmplitude,
                  (v) => t.useSignedAmplitude = v,
                ),
                _toggle('VisualExact', t.visualExact, (v) => t.visualExact = v),
              ],
            ),

            const SizedBox(height: 8),
            Text(
              '튜닝 변경 시 파형이 즉시 갱신돼. (자동 리페인트)',
              style: labelStyle?.copyWith(color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numSlider(
    String title,
    double min,
    double max,
    double value,
    ValueChanged<double> onChanged, {
    String? suffix,
  }) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(title)),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            value: value.clamp(min, max),
            onChanged: (v) {
              onChanged(v);
              setState(() {});
            },
          ),
        ),
        SizedBox(
          width: 72,
          child: Text('${value.toStringAsFixed(2)}${suffix ?? ''}'),
        ),
      ],
    );
  }

  Widget _toggle(String title, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      selected: value,
      label: Text(title),
      onSelected: (v) {
        onChanged(v);
        setState(() {});
      },
    );
  }
}
