// lib/services/workspace_service.dart
// v1.6.0 | WORKSPACE_DIR 자동 교정 + 권한/존재 보장 + 안전 폴백
// - /Users/you 하드코딩 방지: 런타임에 사용자 홈으로 자동 교정
// - folderPath 생략 시 자동으로 워크스페이스 경로 결정
// - 쓰기 권한/상위 디렉터리 존재 보장 + 실패 시 단계적 폴백
// - 기존: 루트 재귀 감시(startRoot) / 단일 학생 감시(start) 로직은 동일
// - 파일 업로드 후 오늘레슨 링크 생성(기존 v1.1.0 로직 유지)

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase/supabase_tables.dart';
import '../models/resource.dart';
import 'lesson_links_service.dart';

class WorkspaceService {
  WorkspaceService._();
  static final WorkspaceService instance = WorkspaceService._();

  StreamSubscription<FileSystemEvent>? _sub;

  static const _allowExt = {
    '.m4a',
    '.mp3',
    '.wav',
    '.aif',
    '.aiff',
    '.mp4',
    '.mov',
    '.xsc',
  };

  bool get isRunning => _sub != null;

  // ===== 신규: 워크스페이스 자동 결정 =====
  Future<Directory> _ensureWorkspaceDir() async {
    // 1) dart-define
    final fromDefine = const String.fromEnvironment('WORKSPACE_DIR').trim();
    final home = Platform.environment['HOME'];
    final candidates = <String>[];

    if (fromDefine.isNotEmpty) {
      var fixed = fromDefine;
      // /Users/you 방지 → 실제 사용자 홈으로 교정
      if (fixed.startsWith('/Users/you/')) {
        if (home != null && home.startsWith('/Users/')) {
          fixed = p.join(home, fixed.substring('/Users/you/'.length));
        } else if (home != null && home.isNotEmpty) {
          fixed = p.join(home, 'GuitarTreeWorkspace');
        }
      }
      candidates.add(fixed);
    }

    // 2) 사용자 홈 기본 위치들
    if (home != null && home.isNotEmpty) {
      candidates.add(p.join(home, 'GuitarTreeWorkspace'));
      candidates.add(p.join(home, 'Downloads', 'GuitarTreeWorkspace'));
    }

    // 3) 앱 지원 디렉토리
    try {
      // path_provider는 macOS에서만 동작. 현재 파일은 macOS 운용이 전제.
      // ignore: depend_on_referenced_packages
      final support = await (await dynamicLibraryLoader())
          .getApplicationSupportDirectory();
      candidates.add(p.join(support.path, 'GuitarTreeWorkspace'));
    } catch (_) {
      // 무시하고 다음 후보로 진행
    }

    // 후보들 중 최초로 "상위 존재 + 쓰기 가능"한 경로 채택
    for (final path in candidates) {
      if (path.isEmpty) continue;
      try {
        final dir = Directory(path);
        if (!await dir.exists()) {
          final parent = dir.parent;
          if (await parent.exists()) {
            await dir.create(recursive: true);
          } else {
            // 상위가 사용자 홈 하위인지 확인 후에만 생성 허용
            if (home != null && p.isWithin(home, path)) {
              await dir.create(recursive: true);
            } else {
              continue;
            }
          }
        }
        // 쓰기 권한 테스트
        final probe = File(p.join(dir.path, '.gt_write_test'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return dir;
      } catch (_) {
        // 다음 후보 시도
      }
    }

    throw FileSystemException('No writable workspace directory found.');
  }

  // NOTE: path_provider를 동적으로 참조하기 위한 미니 래퍼 (웹/다른 플랫폼 빌드 회피)
  Future<_SupportDir> dynamicLibraryLoader() async {
    // ignore: avoid_dynamic_calls
    final lib = await Future.value(null);
    return _SupportDir();
  }

  // ===== A) 루트 재귀 감시: 경로 규칙으로 학생 자동 매칭 =====
  Future<void> startRoot({String? folderPath}) async {
    await stop();
    if (!Platform.isMacOS) return;

    final baseDir = folderPath != null
        ? Directory(folderPath)
        : await _ensureWorkspaceDir();
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    _sub = baseDir
        .watch(events: FileSystemEvent.create, recursive: true)
        .listen((evt) async {
          if (evt is! FileSystemCreateEvent) return;
          final path = evt.path;
          final ext = p.extension(path).toLowerCase();
          if (!_allowExt.contains(ext)) return;

          try {
            final studentId = await _resolveStudentIdFromPath(path);
            if (studentId == null || studentId.isEmpty) return;
            await _handleFileUploadAndLink(path: path, studentId: studentId);
          } catch (_) {
            // 조용히 무시
          }
        });
  }

  // ===== B) 단일 학생용 감시(기존 호환) =====
  Future<void> start({String? folderPath, required String studentId}) async {
    await stop();
    if (!Platform.isMacOS) return;

    final baseDir = folderPath != null
        ? Directory(folderPath)
        : await _ensureWorkspaceDir();
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    _sub = baseDir.watch(events: FileSystemEvent.create).listen((evt) async {
      if (evt is! FileSystemCreateEvent) return;
      final path = evt.path;
      final ext = p.extension(path).toLowerCase();
      if (!_allowExt.contains(ext)) return;

      try {
        await _handleFileUploadAndLink(path: path, studentId: studentId);
      } catch (_) {
        // 조용히 무시
      }
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  // ===== 내부 유틸 =====

  Future<void> _handleFileUploadAndLink({
    required String path,
    required String studentId,
  }) async {
    final file = File(path);

    // 파일 크기 안정화(폴링)
    var last = -1;
    for (int i = 0; i < 20; i++) {
      final len = await file.length();
      if (len == last) break;
      last = len;
      await Future.delayed(const Duration(milliseconds: 250));
    }

    final name = p.basename(path);
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    final storagePath = '$y-$m/$studentId/$name';
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

    await LessonLinksService().sendResourceToTodayLesson(
      studentId: studentId,
      resource: rf,
    );
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
    final reg = RegExp(r'^(.+)[_\s-](\d{4})$'); // 이름_1234 / 이름-1234 / 이름 1234
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
      if (res is Map && res['id'] != null) {
        return res['id'] as String;
      }
      if (res is List && res.isNotEmpty && res.first is Map) {
        final first = res.first as Map;
        final id = first['id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) {}
    return null;
  }
}

// ---- 내부 헬퍼 (path_provider 대체용 최소 래퍼) ----
class _SupportDir {
  Future<Directory> getApplicationSupportDirectory() async {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final dir = Directory(p.join(home, 'Library', 'Application Support'));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    // 최후 폴백: /tmp
    final dir = Directory('/tmp');
    return dir;
  }
}
