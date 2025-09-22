// lib/services/workspace_service.dart
// v1.6.2 | 워크스페이스 자동 교정 + 경로별 디바운스(필드) + stop() 정리 + 첨부 메타 insert
// - XSC 제외 (XscSyncService 전담)
// - 숨김/임시 파일 필터
// - create|modify|move 감시
// - lesson_attachments 테이블에도 메타 insert (선택 기능이지만 활성화)
// - 불필요 import 제거(uuid)

import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' show sha1;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:typed_data';
import 'file_key_util.dart';
import '../supabase/supabase_tables.dart';
import '../models/resource.dart';
import 'lesson_links_service.dart' hide FileKeyUtil;

import 'package:path_provider/path_provider.dart' as pp;

class WorkspaceService {
  WorkspaceService._();
  static final WorkspaceService instance = WorkspaceService._();

  StreamSubscription<FileSystemEvent>? _sub;

  // 경로별 디바운스(중복 업로드 방지)
  final Map<String, Timer> _debounces = {};
  void _schedule(String path, void Function() run) {
    _debounces[path]?.cancel();
    _debounces[path] = Timer(const Duration(milliseconds: 600), () {
      _debounces.remove(path)?.cancel();
      run();
    });
  }

  // ⚠️ .xsc 제거: XscSyncService가 관리
  static const _allowExt = {
    '.m4a',
    '.mp3',
    '.wav',
    '.aif',
    '.aiff',
    '.mp4',
    '.mov',
    // '.xsc'  ← 제외
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
      final support = await pp.getApplicationSupportDirectory();
      candidates.add(p.join(support.path, 'GuitarTreeWorkspace'));
    } catch (_) {
      // 무시
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

  // ===== 공통: 파일 필터 =====
  bool _isHiddenOrTemp(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.startsWith('.')) return true; // ._foo, .ds_store 등
    if (name.startsWith('.sb-')) return true; // 일부 앱 임시 프리픽스
    if (name.endsWith('~')) return true; // foo~
    if (name.endsWith('.tmp')) return true; // foo.tmp
    return false;
  }

  Future<String> _sha1OfFile(String path) async {
   final f = File(path);
   final bytes = await f.readAsBytes();
   return sha1.convert(bytes).toString();
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
        .watch(
          events:
              FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.move,
          recursive: true,
        )
        .listen((evt) async {
          final path = evt.path;
          // 파일이 아니거나 임시/숨김이면 무시
          try {
            final st = await File(path).stat();
            if (st.type != FileSystemEntityType.file) return;
          } catch (_) {
            return;
          }
          if (_isHiddenOrTemp(path)) return;

          final ext = p.extension(path).toLowerCase();
          if (ext == '.xsc') return; // ❗ XSC는 여기서 다루지 않음
          if (!_allowExt.contains(ext)) return;

          _schedule(path, () async {
            try {
              final studentId = await _resolveStudentIdFromPath(path);
              if (studentId == null || studentId.isEmpty) return;
              await _handleFileUploadAndLink(path: path, studentId: studentId);
            } catch (_) {
              // 조용히 무시
            }
          });
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
          if (ext == '.xsc') return; // ❗ XSC 제외
          if (!_allowExt.contains(ext)) return;

          _schedule(path, () async {
            try {
              await _handleFileUploadAndLink(path: path, studentId: studentId);
            } catch (_) {
              // 조용히 무시
            }
          });
        });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    // 디바운스 타이머 정리
    for (final t in _debounces.values) {
      t.cancel();
    }
    _debounces.clear();
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
    final ext = p.extension(name).toLowerCase();
    final now = DateTime.now();

    // === .xsc는 여기서 무시(XscSyncService 담당) ===
    if (ext == '.xsc') {
      return;
    }

    // === 오디오/영상 → lesson_attachments 버킷 업로드 후 "오늘 레슨 링크" 생성 ===
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    // 안전한 파일명(키용)으로 교체
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

    // ResourceFile로 감싼 뒤 "오늘 레슨 링크"로 전송
    final rf = ResourceFile.fromMap({
      'id': '',
      'curriculum_node_id': null,
      'title': name, // UI 표시: 원본 한글
      'filename': name,
      'mime_type': null,
      'size_bytes': await file.length(),
      'storage_bucket': SupabaseBuckets.lessonAttachments,
      'storage_path': storagePath, // ASCII-safe 키
      'created_at': now.toIso8601String(),
    });

    // 링크 생성 (오늘 레슨 보장)
    final links = LessonLinksService();
    await links.sendResourceToTodayLesson(studentId: studentId, resource: rf);

    // (선택) lesson_attachments 테이블에도 메타 insert — 통계/관리용
    try {
      final lessonId = await links.getTodayLessonId(studentId, ensure: true);
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
    } catch (_) {
      // RLS/권한 상황에 따라 실패할 수 있으므로 조용히 무시
    }
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
