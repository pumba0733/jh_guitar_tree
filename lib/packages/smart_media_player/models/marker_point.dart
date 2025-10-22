//lib/packages/smart_media_player/models/marker_point.dart
import 'package:flutter/material.dart';

/// 연주 지점 북마크
class MarkerPoint {
  Duration t;
  String label;
  String? note;
  Color? color;

  MarkerPoint(this.t, this.label, {this.note, this.color});

  Map<String, dynamic> toJson() => {
    't': t.inMilliseconds,
    'label': label,
    if (note != null) 'note': note,
    if (color != null) 'color': _colorToHex(color!),
  };

  static MarkerPoint fromJson(Map<String, dynamic> m) => MarkerPoint(
    Duration(milliseconds: (m['t'] ?? 0) as int),
    (m['label'] ?? '') as String,
    note: (m['note'] as String?),
    color: _tryParseColor(m['color'] as String?),
  );

  // ----- helpers -----
  static Color? _tryParseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      var v = hex.toUpperCase().replaceAll('#', '');
      if (v.length == 6) v = 'FF$v';
      final n = int.parse(v, radix: 16);
      return Color(n);
    } catch (_) {
      return null;
    }
  }

  static String _colorToHex(Color c) {
    // ARGB -> #RRGGBB (불투명 가정)
    final a = c.alpha;
    final r = c.red.toRadixString(16).padLeft(2, '0');
    final g = c.green.toRadixString(16).padLeft(2, '0');
    final b = c.blue.toRadixString(16).padLeft(2, '0');
    // a가 255가 아니면 #AARRGGBB 로 저장해도 됨. 지금은 #RRGGBB 고정.
    return '#${(r + g + b).toUpperCase()}';
  }
}
