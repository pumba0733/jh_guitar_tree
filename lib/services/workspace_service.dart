// lib/services/workspace_service.dart
// v1.1.0 | macOS 전용 워크스페이스(루트 재귀 감시) → lesson_attachments 업로드 → 오늘 레슨 리소스 링크 자동 생성
// - startRoot(folderPath): 루트 경로 1개만으로 멀티학생 자동 매칭 (UUID 또는 이름_전화뒤4 규칙)
// - start(folderPath, studentId): 단일 학생용 감시(기존 호환)
// - 파일 생성 이벤트 감지 후 크기 안정화 확인 → Storage 업로드 → LessonLinksService.sendResourceToTodayLesson()
// - 실패/미매칭은 조용히 무시(필요 시 LogService 연동 가능)

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

  // ===== A) 루트 재귀 감시: 경로 규칙으로 학생 자동 매칭 =====
  Future<void> startRoot({required String folderPath}) async {
    await stop();

    // macOS 전용 가드 (안전망)
    if (!Platform.isMacOS) return;

    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 재귀 감시: 하위 모든 디렉토리 포함
    _sub = dir.watch(events: FileSystemEvent.create, recursive: true).listen((
      evt,
    ) async {
      if (evt is! FileSystemCreateEvent) return;
      final path = evt.path;
      final ext = p.extension(path).toLowerCase();
      if (!_allowExt.contains(ext)) return;

      try {
        final studentId = await _resolveStudentIdFromPath(path);
        if (studentId == null || studentId.isEmpty) {
          // 매칭 불가 → 조용히 스킵
          return;
        }
        await _handleFileUploadAndLink(path: path, studentId: studentId);
      } catch (_) {
        // 조용히 무시 (필요 시 LogService로 전달)
      }
    });
  }

  // ===== B) 단일 학생용 감시(기존 호환) =====
  Future<void> start({
    required String folderPath,
    required String studentId,
  }) async {
    await stop();

    // macOS 전용 가드 (안전망)
    if (!Platform.isMacOS) return;

    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    _sub = dir.watch(events: FileSystemEvent.create).listen((evt) async {
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

    // 파일 크기 안정화 (간단 폴링)
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

    // 오늘 레슨에 리소스 링크 생성
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

  // 경로에서 학생 식별 규칙:
  // 1) UUID가 보이면 그걸 studentId로 사용
  // 2) 세그먼트 중 '이름_1234' 패턴 발견 시 → RPC(find_student)로 id 조회
  Future<String?> _resolveStudentIdFromPath(String fullPath) async {
    // 1) UUID 우선
    final uuid = _findUuidInPath(fullPath);
    if (uuid != null) return uuid;

    // 2) 이름_전화뒤4 패턴
    final pair = _findNameLast4InPath(fullPath);
    if (pair != null) {
      final (name, last4) = pair;
      final id = await _rpcFindStudentId(name: name, phoneLast4: last4);
      if (id != null && id.isNotEmpty) return id;
    }

    return null;
  }

  String? _findUuidInPath(String path) {
    // 대소문자 무시, 36자 하이픈 포함 UUID
    final reg = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    );
    final m = reg.firstMatch(path);
    return m?.group(0);
  }

  // 세그먼트에서 '이름_1234' 찾기 (예: /Workspace/홍길동_1234/녹음.mp3)
  (String, String)? _findNameLast4InPath(String path) {
    final segments = p.split(path);
    final reg = RegExp(r'^(.+)[_\s-](\d{4})$'); // 이름_1234 / 이름-1234 / 이름 1234
    for (final seg in segments.reversed) {
      final m = reg.firstMatch(seg);
      if (m != null) {
        final name = m.group(1)!.trim();
        final last4 = m.group(2)!.trim();
        if (name.isNotEmpty) {
          return (name, last4);
        }
      }
    }
    return null;
  }

  // Supabase RPC: find_student(name, phone_last4) → { id, ... } 1건 반환 가정
  Future<String?> _rpcFindStudentId({
    required String name,
    required String phoneLast4,
  }) async {
    try {
      final supa = Supabase.instance.client;
      // 파라미터 키는 실제 RPC 정의에 맞게 조정 (예: p_name, p_phone_last4 등)
      final res = await supa.rpc(
        'find_student',
        params: {'p_name': name, 'p_phone_last4': phoneLast4},
      );
      // res가 Map 또는 List로 올 수 있으니 방어
      if (res is Map && res['id'] != null) {
        return res['id'] as String;
      }
      if (res is List && res.isNotEmpty && res.first is Map) {
        final first = res.first as Map;
        final id = first['id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) {
      // RPC 실패는 조용히 무시
    }
    return null;
  }
}
