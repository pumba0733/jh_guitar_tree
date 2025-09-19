// lib/services/xsc_sync_service.dart
// v1.55.1-fix | Transcribe(xsc) 프리/포스트 동기화 (공유 mp3 + 학생별 xsc)
// - Uint8List import 누락 보완
// - 하드링크 대신 심볼릭 링크(Link) → 실패 시 복사로 폴백
// - Supabase list 정렬 시 updatedAt의 타입 명시적 처리(Object → DateTime)
// - 나머지 로직 동일

import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io';
import 'dart:typed_data';
import 'lesson_links_service.dart';

import 'package:crypto/crypto.dart' show sha1;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';
import 'file_service.dart';
import 'resource_service.dart';

class XscSyncService {
  XscSyncService._();
  static final XscSyncService instance = XscSyncService._();
  factory XscSyncService() => instance;

  final _sb = Supabase.instance.client;
  final _res = ResourceService();
  final _file = FileService();

  // ---- config ----
  static const String studentXscBucket = 'student_xsc';
  static const String curriculumBucket = ResourceService.bucket;

  // -- WORKSPACE_DIR: flutter run --dart-define=WORKSPACE_DIR=/... 로 주입
  static const String _wsDir = String.fromEnvironment(
    'WORKSPACE_DIR',
    defaultValue: '',
  );

  // watcher
  StreamSubscription<FileSystemEvent>? _sub;

  Future<void> disposeWatcher() async {
    await _sub?.cancel();
    _sub = null;
  }

  // ========== Public API ==========
  /// 오늘레슨 링크(Map)를 받아 mp3 리소스면 xsc 동기화 경로로 열기
  Future<void> openFromLessonLinkMap({
    required Map<String, dynamic> link,
    required String studentId,
  }) async {
    final kind = (link['kind'] ?? '').toString();
    if (kind != 'resource') {
      throw ArgumentError('resource 링크가 아닙니다.');
    }
    final rf = ResourceFile.fromMap({
      'id': link['id'],
      'curriculum_node_id': link['curriculum_node_id'],
      'title': link['resource_title'],
      'filename': link['resource_filename'],
      'mime_type': null,
      'size_bytes': null,
      'storage_bucket': link['resource_bucket'] ?? curriculumBucket,
      'storage_path': link['resource_path'] ?? '',
      'created_at': link['created_at'],
    });
    await open(resource: rf, studentId: studentId);
  }

  /// mp3 리소스를 열 때:
  /// - 프리: 공유 mp3 로컬 캐시 + 학생폴더 구성 + 최신 xsc 다운로드
  /// - 오픈: xsc 있으면 xsc, 없으면 mp3
  /// - 포스트: 학생폴더 감시하여 저장 시 자동 업로드
  Future<void> open({
    required ResourceFile resource,
    required String studentId,
  }) async {
    final isAudioMp3 =
        resource.filename.toLowerCase().endsWith('.mp3') ||
        (resource.mimeType?.contains('audio') ?? false);

    // mp3가 아니면 그냥 URL로 오픈
    if (!isAudioMp3) {
      final url = await _res.signedUrl(resource);
      await _file.openUrl(url);
      return;
    }

    // 1) 공유 mp3 캐시 확보
    final sharedMp3Path = await _ensureSharedMp3(resource);

    // 2) 학생 폴더(<ws>/<studentId>/<mp3Hash>/) 생성
    final mp3Hash = await _sha1OfFile(sharedMp3Path);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mp3Hash));

    // 3) mp3를 학생 폴더에 심볼릭 링크(실패 시 복사)로 배치
    final linkedMp3 = await _linkOrCopySharedMp3(
      sharedMp3Path: sharedMp3Path,
      studentMp3Dir: studentDir,
    );

    // 4) 최신 xsc 내려받기(있으면 current.xsc로)
    final localXsc = await _downloadLatestXscIfAny(
      studentId: studentId,
      mp3Hash: mp3Hash,
      intoDir: studentDir,
    );

    // 5) 기본앱 실행
    final toOpen = localXsc ?? linkedMp3;
    await _file.openLocal(toOpen);

    // 6) 저장 감시 시작 → 변경 시 업로드(current.xsc + backups)
    await _watchAndSyncXsc(
      dir: studentDir,
      studentId: studentId,
      mp3Hash: mp3Hash,
    );
  }

  // ========== Pre-open helpers ==========

  Future<String> _ensureSharedMp3(ResourceFile resource) async {
    final url = await _res.signedUrl(resource);

    // mp3 다운로드 → 임시 저장
    final tmp = await FileService.saveBytesFile(
      filename: resource.filename,
      bytes: await _downloadBytes(url),
    );

    // 해시 디렉토리(.shared_cache/<hash>/)로 이동/보관
    final cacheRoot = await _ensureDir(p.join(_workspace(), '.shared_cache'));
    final h = await _sha1OfFile(tmp.path);
    final hashDir = await _ensureDir(p.join(cacheRoot, h));
    final outPath = p.join(hashDir, resource.filename);
    final out = File(outPath);
    if (!out.existsSync()) {
      await File(tmp.path).copy(outPath);
    }
    return outPath;
  }

  Future<Uint8List> _downloadBytes(String url) async {
    final http = HttpClient();
    final rq = await http.getUrl(Uri.parse(url));
    final rs = await rq.close();
    if (rs.statusCode != 200) {
      throw StateError('mp3 다운로드 실패(${rs.statusCode})');
    }
    final bytes = await rs.fold<List<int>>([], (a, b) => a..addAll(b));
    return Uint8List.fromList(bytes);
  }

  Future<String> _sha1OfFile(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    return sha1.convert(bytes).toString(); // 40자 hex
  }

  String _workspace() {
    // 1) 후보 경로들 준비
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      if (_wsDir.isNotEmpty) _wsDir, // --dart-define
      Platform.environment['WORKSPACE_DIR'] ?? '', // 환경변수로도 허용
      if (home != null && home.isNotEmpty)
        p.join(home, 'GuitarTreeWorkspace'), // ~/GuitarTreeWorkspace
      p.join(Directory.systemTemp.path, 'GuitarTreeWorkspace'), // 최후 폴백
    ].where((e) => e.trim().isNotEmpty).toList();

    // 2) 존재/생성 가능한 첫 경로 사용
    for (final c in candidates) {
      try {
        final d = Directory(c);
        if (!d.existsSync()) {
          d.createSync(recursive: true);
        }
        return d.path;
      } catch (_) {
        // 실패하면 다음 후보로
      }
    }

    // 3) 최종 폴백(무조건 가능한 temp)
    return Directory.systemTemp.createTempSync('GuitarTreeWorkspace_').path;
  }

  Future<String> _ensureStudentRoot(String studentId) async {
    return _ensureDir(p.join(_workspace(), studentId));
  }

  Future<String> _ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d.path;
  }

  Future<String> _linkOrCopySharedMp3({
    required String sharedMp3Path,
    required String studentMp3Dir,
  }) async {
    final dst = p.join(studentMp3Dir, p.basename(sharedMp3Path));

    // 1) 심볼릭 링크 시도
    try {
      if (await Link(dst).exists()) return dst;
      await Link(dst).create(sharedMp3Path, recursive: true);
      return dst;
    } catch (_) {
      // 2) 폴백: 복사
      final copied = await File(sharedMp3Path).copy(dst);
      return copied.path;
    }
  }

  // ========== Download latest xsc ==========
  Future<String?> _downloadLatestXscIfAny({
    required String studentId,
    required String mp3Hash,
    required String intoDir,
  }) async {
    try {
      final prefix = '$studentId/$mp3Hash/';
      final store = _sb.storage.from(studentXscBucket);

      // list() 반환 타입이 dynamic일 수 있어 명시적으로 다룬다.
      final objsRaw = await store.list(
        path: prefix,
        searchOptions: const SearchOptions(limit: 100),
      );

      // 타입 안전 처리
      final List<dynamic> objsDyn = objsRaw;
      if (objsDyn.isEmpty) return null;

      // 최신(updatedAt) 기준으로 정렬 (current.xsc 우선)
      objsDyn.sort((a, b) {
        DateTime parse(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        final at = parse(a.updatedAt);
        final bt = parse(b.updatedAt);
        return bt.compareTo(at);
      });

      // current.xsc가 있으면 우선
      dynamic current = objsDyn.firstWhere(
        (o) => (o.name as String).toLowerCase() == 'current.xsc',
        orElse: () => objsDyn.first,
      );

      final key = '$prefix${current.name as String}';
      final bytes = await store.download(key);
      final local = File(p.join(intoDir, 'current.xsc'));
      await local.writeAsBytes(bytes, flush: true);
      return local.path;
    } catch (_) {
      return null;
    }
  }

  // ========== Watch & upload ==========
  Future<void> _watchAndSyncXsc({
    required String dir,
    required String studentId,
    required String mp3Hash,
  }) async {
    await disposeWatcher();

    final folder = Directory(dir);
    if (!await folder.exists()) return;

    // 파일별 디바운스 타이머
    final Map<String, Timer> debounces = {};
    // 업로드 중복 방지 락
    final Map<String, bool> busy = {};

    bool isTempOrHidden(String path) {
      final name = p.basename(path).toLowerCase();
      if (name.startsWith('.')) return true; // ._foo, .~lock 등
      if (name.endsWith('~')) return true; // foo.xsc~
      if (name.endsWith('.tmp')) return true; // foo.tmp
      if (name.startsWith('~\$')) return true;
      if (name.startsWith('.sb-')) return true; // 일부 앱 임시 프리픽스
      return false;
    }

    Future<void> uploadOnce(String path) async {
      if (busy[path] == true) return;
      busy[path] = true;
      try {
        // 파일 크기 안정화
        final f = File(path);
        var last = -1;
        for (int i = 0; i < 16; i++) {
          final len = await f.length();
          if (last == len) break;
          last = len;
          await Future.delayed(const Duration(milliseconds: 200));
        }

        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mp3Hash/';

        // 백업
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        final backupKey = '${prefix}backups/$ts.xsc';
        await store.upload(
          backupKey,
          f,
          fileOptions: const FileOptions(upsert: false),
        );

        // current 교체
        final curKey = '${prefix}current.xsc';
        await store.upload(
          curKey,
          f,
          fileOptions: const FileOptions(upsert: true),
        );

        // (선택) UI 메타 즉시 갱신
        await LessonLinksService().touchXscUpdatedAt(
          studentId: studentId,
          mp3Hash: mp3Hash,
        );
      } catch (_) {
        // 조용히 무시(로그는 상위에서 처리)
      } finally {
        busy[path] = false;
      }
    }

    void scheduleUpload(String path) {
      debounces[path]?.cancel();
      debounces[path] = Timer(const Duration(milliseconds: 800), () {
        debounces[path]?.cancel();
        debounces.remove(path);
        unawaited(uploadOnce(path));
      });
    }

    _sub = folder
        .watch(
          events:
              FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.move,
          recursive: false, // mp3Hash 전용 폴더 — 비재귀 권장
        )
        .listen((evt) async {
          final path = evt.path.toString();
          final lower = path.toLowerCase();

          if (!lower.endsWith('.xsc')) return;
          if (isTempOrHidden(path)) return;

          // 임시명 → rename 패턴 대응: .xsc면 디바운스로 업로드 스케줄
          scheduleUpload(path);
        });
  }
}
