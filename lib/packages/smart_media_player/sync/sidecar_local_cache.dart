// lib/packages/smart_media_player/sync/sidecar_local_cache.dart
// v3.08.0 | 로컬 캐시: Desktop/Mobile은 파일, Web은 no-op
//
// 의존: dart:io (웹에서는 import 되지만 kIsWeb 조건으로 사용 안 함)

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

typedef Json = Map<String, dynamic>;

class SidecarLocalCache {
  static Future<String?> _resolvePath({
    required String? baseDir,
    required String studentId,
    required String mediaHash,
  }) async {
    if (kIsWeb) return null; // web은 no-op
    if (baseDir == null || baseDir.isEmpty) return null;
    final dir = Directory(p.join(baseDir, 'sidecar_local'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return p.join(dir.path, '${studentId}_$mediaHash.json');
  }

  static Future<Json?> readJson({
    required String? baseDir,
    required String studentId,
    required String mediaHash,
  }) async {
    try {
      final path = await _resolvePath(
        baseDir: baseDir,
        studentId: studentId,
        mediaHash: mediaHash,
      );
      if (path == null) return null;
      final f = File(path);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      return jsonDecode(raw) as Json;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeJson({
    required String? baseDir,
    required String studentId,
    required String mediaHash,
    required Json data,
  }) async {
    try {
      final path = await _resolvePath(
        baseDir: baseDir,
        studentId: studentId,
        mediaHash: mediaHash,
      );
      if (path == null) return;
      final f = File(path);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } catch (_) {
      // ignore
    }
  }
}
