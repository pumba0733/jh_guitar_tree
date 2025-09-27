// v1.7.0 | Workspace watcher (Windows + macOS 지원)
// - macOS 전용 가드 제거 → Windows도 감시/업로드 활성화
// - 워크스페이스 경로 탐색에 USERPROFILE(Win) 지원 추가
// - 숨김/임시 파일 필터 보강(Thumbs.db, desktop.ini 등)
// - 파일 안정화 폴링/디바운스 유지, XSC는 제외( XscSyncService 담당 )
// - lesson_attachments 버킷 업로드 후 오늘 레슨 링크 자동 생성

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
  };

  bool get isRunning => _sub != null;

  // ===== 신규: 워크스페이스 자동 결정 (Win/mac 공통) =====
  Future<Directory> _ensureWorkspaceDir() async {
    final fromDefine = const String.fromEnvironment('WORKSPACE_DIR').trim();

    // 홈 경로: macOS=HOME, Windows=USERPROFILE 우선
    final home = Platform.environment['HOME'];
    final userProfile = Platform.environment['USERPROFILE'];
    final String? osHome = (Platform.isWindows ? userProfile : home);

    final candidates = <String>[];

    // 1) dart-define
    if (fromDefine.isNotEmpty) {
      var fixed = fromDefine;

      // macOS 기본 템플릿 교정
      if (!Platform.isWindows && fixed.startsWith('/Users/you/')) {
        if (osHome != null && osHome.startsWith('/Users/')) {
          fixed = p.join(osHome, fixed.substring('/Users/you/'.length));
        } else if (osHome != null && osHome.isNotEmpty) {
          fixed = p.join(osHome, 'GuitarTreeWorkspace');
        }
      }

      // Windows에서 흔한 예: C:\Users\you\GuitarTreeWorkspace → 실제 사용자로 교정
      if (Platform.isWindows && fixed.contains(r'\you\')) {
        if (osHome != null && osHome.isNotEmpty) {
          // \you\ 이후 하위 경로를 보존해 붙인다
          final idx = fixed.toLowerCase().indexOf(r'\you\');
          final tail = idx >= 0
              ? fixed.substring(idx + r'\you'.length)
              : r'\GuitarTreeWorkspace';
          fixed = p.join(osHome, tail);
        }
      }
      candidates.add(fixed);
    }

    // 2) 사용자 홈 기본 위치들
    if (osHome != null && osHome.isNotEmpty) {
      candidates.add(p.join(osHome, 'GuitarTreeWorkspace'));
      // Windows는 Downloads 폴더가 지역화될 수 있으므로 안전하게 홈 하위만 추가
      if (!Platform.isWindows) {
        candidates.add(p.join(osHome, 'Downloads', 'GuitarTreeWorkspace'));
      }
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
            // 상위가 홈 하위인지 확인 후에만 생성 허용
            if (osHome != null && p.isWithin(osHome, path)) {
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

    // 마지막 수단: 시스템 임시
    final fallback = Directory.systemTemp.createTempSync(
      'GuitarTreeWorkspace_',
    );
    return fallback;
  }

  // ===== 공통: 파일 필터 =====
  bool _isHiddenOrTemp(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.startsWith('.')) return true; // macOS 숨김
    if (name.startsWith('.sb-')) return true; // 임시 프리픽스
    if (name.endsWith('~')) return true; // foo~
    if (name.endsWith('.tmp')) return true; // foo.tmp
    if (name == 'thumbs.db') return true; // Windows
    if (name == 'desktop.ini') return true; // Windows
    return false;
  }

  Future<String> _sha1OfFile(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    return sha1.convert(bytes).toString();
  }

  // ===== A) 루트 재귀 감시: 경로 규칙으로 학생 자동 매칭 (Win/mac 공통) =====
  Future<void> startRoot({String? folderPath}) async {
    await stop();

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

          // 파일만 처리
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

  // ===== B) 단일 학생용 감시(기존 호환, Win/mac 공통) =====
  Future<void> start({String? folderPath, required String studentId}) async {
    await stop();

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
    for (int i = 0; i < 24; i++) {
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
      'title': name, // UI 표시: 원본 파일명
      'filename': name,
      'mime_type': null,
      'size_bytes': await file.length(),
      'storage_bucket': SupabaseBuckets.lessonAttachments,
      'storage_path': storagePath, // ASCII-safe 키
      'created_at': now.toIso8601String(),
    });

    final links = LessonLinksService();
    await links.sendResourceToTodayLesson(studentId: studentId, resource: rf);

    // (선택) lesson_attachments 테이블에도 메타 insert — 통계/관리용
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
