// lib/packages/smart_media_player/sync/sidecar.dart
// v1.0.0 — Sidecar JSON model + disk helpers (independent from SidecarSync)

import 'dart:convert';
import 'dart:io';

class SmartMediaSidecar {
  final String studentId;
  final String mediaHash;
  final double speed; // 0.5..1.5
  final int pitchSemi; // -7..+7
  final int loopAms;
  final int loopBms;
  final bool loopOn;
  final int loopRepeat;
  final int positionMs;
  final int startCueMs;
  final String mediaName;
  final String notes;
  final int volume; // 0..150
  final String savedAtIso; // ISO8601
  final String version; // e.g., v3.07.1
  final List<Map<String, dynamic>> markers;

  const SmartMediaSidecar({
    required this.studentId,
    required this.mediaHash,
    required this.speed,
    required this.pitchSemi,
    required this.loopAms,
    required this.loopBms,
    required this.loopOn,
    required this.loopRepeat,
    required this.positionMs,
    required this.startCueMs,
    required this.mediaName,
    required this.notes,
    required this.volume,
    required this.savedAtIso,
    required this.version,
    required this.markers,
  });

  Map<String, dynamic> toJson() => {
    'studentId': studentId,
    'mediaHash': mediaHash,
    'speed': speed,
    'pitchSemi': pitchSemi,
    'loopA': loopAms,
    'loopB': loopBms,
    'loopOn': loopOn,
    'loopRepeat': loopRepeat,
    'positionMs': positionMs,
    'startCueMs': startCueMs,
    'media': mediaName,
    'notes': notes,
    'volume': volume,
    'savedAt': savedAtIso,
    'version': version,
    'markers': markers,
  };

  static SmartMediaSidecar fromJson(Map<String, dynamic> m) {
    return SmartMediaSidecar(
      studentId: (m['studentId'] ?? '').toString(),
      mediaHash: (m['mediaHash'] ?? '').toString(),
      speed: ((m['speed'] ?? 1.0) as num).toDouble(),
      pitchSemi: ((m['pitchSemi'] ?? 0) as num).toInt(),
      loopAms: ((m['loopA'] ?? 0) as num).toInt(),
      loopBms: ((m['loopB'] ?? 0) as num).toInt(),
      loopOn: m['loopOn'] == true,
      loopRepeat: ((m['loopRepeat'] ?? 0) as num).toInt(),
      positionMs: ((m['positionMs'] ?? 0) as num).toInt(),
      startCueMs: ((m['startCueMs'] ?? 0) as num).toInt(),
      mediaName: (m['media'] ?? '').toString(),
      notes: (m['notes'] ?? '').toString(),
      volume: ((m['volume'] ?? 100) as num).toInt(),
      savedAtIso: (m['savedAt'] ?? '').toString(),
      version: (m['version'] ?? '').toString(),
      markers:
          (m['markers'] as List?)
              ?.whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          const [],
    );
  }

  /// Load from disk if exists. Returns empty map on failure.
  static Future<Map<String, dynamic>> loadJsonFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return <String, dynamic>{};
      final txt = await f.readAsString();
      return jsonDecode(txt) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Save (atomic) to disk.
  static Future<void> saveJsonFile(
    String path,
    Map<String, dynamic> json,
  ) async {
    final f = File(path);
    final dir = f.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final tmp = File('${path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    await tmp.rename(path);
  }

  /// LWW (LastWriteWins): choose newer by savedAt ISO timestamp.
  static Map<String, dynamic> lww(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    DateTime? ta, tb;
    try {
      ta = DateTime.tryParse((a['savedAt'] ?? '').toString());
    } catch (_) {}
    try {
      tb = DateTime.tryParse((b['savedAt'] ?? '').toString());
    } catch (_) {}
    if (ta == null && tb == null) return a;
    if (ta == null) return b;
    if (tb == null) return a;
    return tb.isAfter(ta) ? b : a;
  }
}
