// v1.7.1 | Workspace watcher (Windows + macOS 지원) — 컨테이너 우선 폴백 강화
// - macOS 샌드박스에서 HOME 직접 쓰기 시도 회피: AppSupport(컨테이너) 경로를 최우선
// - USERPROFILE/HOME 후보는 실패 시 조용히 스킵, 최종 임시 폴더로 폴백
// - 나머지 기능 동일

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' show sha1;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'file_key_util.dart';
import '../supabase/supabase_tables.dart';
import '../models/resource.dart';
import 'lesson_links_service.dart';
import 'package:path_provider/path_provider.dart' as pp;

class WorkspaceService {
  WorkspaceService._();
  static final WorkspaceService instance = WorkspaceService._();

  StreamSubscription<FileSystemEvent>? _sub;

  final Map<String, Timer> _debounces = {};
  void _schedule(String path, void Function() run) {
    _debounces[path]?.cancel();
    _debounces[path] = Timer(const Duration(milliseconds: 600), () {
      _debounces.remove(path)?.cancel();
      run();
    });
  }

  static const _allowExt = {
    '.m4a',
    '.mp3',
    '.wav',
    '.aif',
    '.aiff',
    '.mp4',
    '.mov',
    '.m4v',
    '.mkv',
    '.avi',
  };

  bool get isRunning => _sub != null;

  // ===== 컨테이너(AppSupport) 우선 경로 탐색 =====
  Future<Directory> _ensureWorkspaceDir() async {
    final fromDefine = const String.fromEnvironment('WORKSPACE_DIR').trim();
    final home = Platform.environment['HOME'];
    final userProfile = Platform.environment['USERPROFILE'];
    final String? osHome = (Platform.isWindows ? userProfile : home);

    final candidates = <String>[];

    // 0) AppSupport(샌드박스 내 컨테이너) — 최우선
    try {
      final support = await pp.getApplicationSupportDirectory();
      candidates.add(p.join(support.path, 'GuitarTreeWorkspace'));
    } catch (_) {}

    // 1) dart-define
    if (fromDefine.isNotEmpty) {
      var fixed = fromDefine;
      if (!Platform.isWindows && fixed.startsWith('/Users/you/')) {
        if (osHome != null && osHome.startsWith('/Users/')) {
          fixed = p.join(osHome, fixed.substring('/Users/you/'.length));
        } else if (osHome != null && osHome.isNotEmpty) {
          fixed = p.join(osHome, 'GuitarTreeWorkspace');
        }
      }
      if (Platform.isWindows && fixed.toLowerCase().contains(r'\you\')) {
        if (osHome != null && osHome.isNotEmpty) {
          final idx = fixed.toLowerCase().indexOf(r'\you\');
          final marker = r'\you\';
          final tail = idx >= 0
              ? fixed.substring(idx + marker.length)
              : r'\GuitarTreeWorkspace';
          fixed = p.join(osHome, tail);
        }
      }
      candidates.add(fixed);
    }

    // 2) 사용자 홈 하위(권한 없으면 스킵됨)
    if (osHome != null && osHome.isNotEmpty) {
      candidates.add(p.join(osHome, 'GuitarTreeWorkspace'));
      if (!Platform.isWindows) {
        candidates.add(p.join(osHome, 'Downloads', 'GuitarTreeWorkspace'));
      }
    }

    // 후보 검증
    for (final path in candidates) {
      if (path.isEmpty) continue;
      try {
        final dir = Directory(path);
        if (!await dir.exists()) {
          final parent = dir.parent;
          if (await parent.exists()) {
            await dir.create(recursive: true);
          } else {
            if (Platform.isWindows) {
              // Windows는 홈 하위면 생성 허용
              if (osHome != null && p.isWithin(osHome, path)) {
                await dir.create(recursive: true);
              } else {
                continue;
              }
            } else {
              // macOS 샌드박스는 홈 외부/상위 생성 금지 → 스킵
              continue;
            }
          }
        }
        final probe = File(p.join(dir.path, '.gt_write_test'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return dir;
      } catch (_) {
        // 권한/샌드박스 오류 → 다음 후보
      }
    }

    // 마지막 수단: 시스템 임시
    final fallback = Directory.systemTemp.createTempSync(
      'GuitarTreeWorkspace_',
    );
    return fallback;
  }

  bool _isHiddenOrTemp(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.startsWith('.')) return true;
    if (name.startsWith('.sb-')) return true;
    if (name.endsWith('~')) return true;
    if (name.endsWith('.tmp')) return true;
    if (name == 'thumbs.db') return true;
    if (name == 'desktop.ini') return true;
    return false;
  }

  Future<String> _sha1OfFile(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    return sha1.convert(bytes).toString();
  }

  // ===== A) 루트 재귀 감시 =====
  Future<void> startRoot({String? folderPath}) async {
    await stop();

    final baseDir = folderPath != null
        ? Directory(folderPath)
        : await _ensureWorkspaceDir();
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
      } catch (_) {}
    }

    _sub = baseDir
        .watch(
          events:
              FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.move,
          recursive: true,
        )
        .listen((evt) async {
          final path = evt.path;
          try {
            final st = await File(path).stat();
            if (st.type != FileSystemEntityType.file) return;
          } catch (_) {
            return;
          }
          if (_isHiddenOrTemp(path)) return;

          final ext = p.extension(path).toLowerCase();
          if (ext == '.xsc') return;
          if (!_allowExt.contains(ext)) return;

          _schedule(path, () async {
            try {
              final studentId = await _resolveStudentIdFromPath(path);
              if (studentId == null || studentId.isEmpty) return;
              await _handleFileUploadAndLink(path: path, studentId: studentId);
            } catch (_) {}
          });
        });
  }

  // ===== B) 단일 학생용 감시 =====
  Future<void> start({String? folderPath, required String studentId}) async {
    await stop();

    final baseDir = folderPath != null
        ? Directory(folderPath)
        : await _ensureWorkspaceDir();
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
      } catch (_) {}
    }

    _sub = baseDir
        .watch(
          events:
              FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.move,
          recursive: false,
        )
        .listen((evt) async {
          final path = evt.path;
          try {
            final st = await File(path).stat();
            if (st.type != FileSystemEntityType.file) return;
          } catch (_) {
            return;
          }
          if (_isHiddenOrTemp(path)) return;

          final ext = p.extension(path).toLowerCase();
          if (ext == '.xsc') return;
          if (!_allowExt.contains(ext)) return;

          _schedule(path, () async {
            try {
              await _handleFileUploadAndLink(path: path, studentId: studentId);
            } catch (_) {}
          });
        });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    for (final t in _debounces.values) {
      t.cancel();
    }
    _debounces.clear();
  }

  Future<void> _handleFileUploadAndLink({
    required String path,
    required String studentId,
  }) async {
    final file = File(path);

    var last = -1;
    for (int i = 0; i < 24; i++) {
      final len = await file.length();
      if (len == last) break;
      last = len;
      await Future.delayed(const Duration(milliseconds: 250));
    }

    final name = p.basename(path);
    final ext = p.extension(name).toLowerCase();
    final now = DateTime.now();

    if (ext == '.xsc') return;

    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    final safeName = FileKeyUtil.keySafe(name);
    final storagePath = '$y-$m/$studentId/$safeName';

    final store = Supabase.instance.client.storage.from(
      SupabaseBuckets.lessonAttachments,
    );
    await store.upload(
      storagePath,
      file,
      fileOptions: const FileOptions(upsert: true, cacheControl: '3600'),
    );

    final rf = ResourceFile.fromMap({
      'id': '',
      'curriculum_node_id': null,
      'title': name,
      'filename': name,
      'mime_type': null,
      'size_bytes': await file.length(),
      'storage_bucket': SupabaseBuckets.lessonAttachments,
      'storage_path': storagePath,
      'created_at': now.toIso8601String(),
    });

    final links = LessonLinksService();
    await links.sendResourceToTodayLesson(studentId: studentId, resource: rf);

    try {
      final lessonId = await links.getTodayLessonIdEnsure(studentId);
      if (lessonId != null) {
        final mediaHash = await _sha1OfFile(path);
        await Supabase.instance.client.from('lesson_attachments').insert({
          'lesson_id': lessonId,
          'type': 'file',
          'storage_bucket': SupabaseBuckets.lessonAttachments,
          'storage_key': storagePath,
          'original_filename': name,
          'mp3_hash': mediaHash,
          'media_name': name,
        });
      }
    } catch (_) {}
  }

  Future<String?> _resolveStudentIdFromPath(String fullPath) async {
    final uuid = _findUuidInPath(fullPath);
    if (uuid != null) return uuid;

    final pair = _findNameLast4InPath(fullPath);
    if (pair != null) {
      final (name, last4) = pair;
      final id = await _rpcFindStudentId(name: name, phoneLast4: last4);
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  String? _findUuidInPath(String path) {
    final reg = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    );
    final m = reg.firstMatch(path);
    return m?.group(0);
  }

  (String, String)? _findNameLast4InPath(String path) {
    final segments = p.split(path);
    final reg = RegExp(r'^(.+)[_\s-](\d{4})$');
    for (final seg in segments.reversed) {
      final m = reg.firstMatch(seg);
      if (m != null) {
        final name = m.group(1)!.trim();
        final last4 = m.group(2)!.trim();
        if (name.isNotEmpty) return (name, last4);
      }
    }
    return null;
  }

  Future<String?> _rpcFindStudentId({
    required String name,
    required String phoneLast4,
  }) async {
    try {
      final supa = Supabase.instance.client;
      final res = await supa.rpc(
        'find_student',
        params: {'p_name': name, 'p_phone_last4': phoneLast4},
      );
      if (res is Map && res['id'] != null) return res['id'] as String;
      if (res is List && res.isNotEmpty && res.first is Map) {
        final first = res.first as Map;
        final id = first['id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) {}
    return null;
  }
}
