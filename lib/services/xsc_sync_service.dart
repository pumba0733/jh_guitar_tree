// lib/services/xsc_sync_service.dart
// v1.65.0 | Win/mac 공통: WORKSPACE 후보에 USERPROFILE 추가 + Windows는 항상 copy 배치
// - mp3 한정 로직 → 오디오/비디오 미디어 일반화 유지
// - 캐시/학생폴더/사이드카/충돌/백업 로직 동일

import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';
import 'file_service.dart';
import 'resource_service.dart';
import 'lesson_links_service.dart';
import 'student_service.dart'; 

class XscSyncService {
  XscSyncService._();
  static final XscSyncService instance = XscSyncService._();
  factory XscSyncService() => instance;

  final _sb = Supabase.instance.client;
  final _res = ResourceService();
  final _file = FileService();

  static const String studentXscBucket = 'student_xsc';
  static const String curriculumBucket = ResourceService.bucket;

  static const String _wsDir = String.fromEnvironment(
    'WORKSPACE_DIR',
    defaultValue: '',
  );

  StreamSubscription<FileSystemEvent>? _sub;
  Future<void> disposeWatcher() async {
    await _sub?.cancel();
    _sub = null;
  }

  // [ADD] 이름/MIME로 미디어 판별(첨부 맵에서도 재사용)
  bool _isMediaByNameMime(String name, String? mime) {
    final lowerName = name.toLowerCase();
    final mt = (mime ?? '').toLowerCase();

    const exts = [
      '.mp3',
      '.wav',
      '.aiff',
      '.aif',
      '.flac',
      '.m4a',
      '.mp4',
      '.mov',
      '.m4v',
      '.mkv',
      '.avi',
    ];
    final byExt = exts.any((e) => lowerName.endsWith(e));
    final byMime = mt.startsWith('audio/') || mt.startsWith('video/');
    return byExt || byMime;
  }

  // ---------------- 판별: XSC 대상 미디어인지 ----------------
  bool isMediaEligibleForXsc(ResourceFile r) {
    return _isMediaByNameMime(r.filename, r.mimeType);
  }

  // ---------------- JSON helpers ----------------
  Future<Map<String, dynamic>> _readJsonFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return {};
      final txt = await f.readAsString();
      final j = convert.jsonDecode(txt);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return Map<String, dynamic>.from(j);
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeJsonFile(String path, Map<String, dynamic> data) async {
    try {
      final f = File(path);
      await f.writeAsString(convert.jsonEncode(data), flush: true);
    } catch (_) {}
  }

  // ---------------- Public API ----------------
  Future<void> openFromLessonLinkMap({
    required Map<String, dynamic> link,
    required String studentId,
  }) async {
    if ((link['kind'] ?? '').toString() != 'resource') {
      throw ArgumentError('resource 링크가 아닙니다.');
    }
    final contentHash =
        (link['resource_content_hash'] ?? link['content_hash'] ?? link['hash'])
            ?.toString();

    final rf = ResourceFile.fromMap({
      'id': (link['id'] ?? '').toString(),
      'curriculum_node_id': link['curriculum_node_id'],
      'title': link['resource_title'],
      'filename': (link['resource_filename'] ?? 'resource').toString(),
      'mime_type': link['resource_mime_type'],
      'size_bytes': link['resource_size'],
      'storage_bucket': (link['resource_bucket'] ?? curriculumBucket)
          .toString(),
      'storage_path': (link['resource_path'] ?? '').toString(), // ← 그대로 사용
      'created_at': link['created_at'],
      if (contentHash != null) 'content_hash': contentHash,
    });

    await open(resource: rf, studentId: studentId);
  }

  // [ADD] 첨부(lessons.attachments의 item)에서 열기: URL/경로 기반
  Future<void> openFromAttachment({
    required Map<String, dynamic> attachment,
    required String studentId,
    String? mimeType,
  }) async {
    try {
      await StudentService().attachMeToStudent(studentId);
    } catch (_) {}
    final url = (attachment['url'] ?? attachment['path'] ?? '')
        .toString()
        .trim();
    final nameSrc = (attachment['name'] ?? '').toString().trim();
    final filename = nameSrc.isNotEmpty
        ? nameSrc
        : (url.isNotEmpty ? p.basename(url) : 'media');

    if (url.isEmpty) {
      throw ArgumentError('attachment url/path가 비어 있습니다.');
    }

    // 0) 미디어 여부 판단
    final isMedia = _isMediaByNameMime(filename, mimeType);
    if (!isMedia) {
      await _file.openUrl(url); // 미디어 아니면 그냥 열기
      return;
    }

    // 1) 공유 미디어 캐시 확보
    final sharedMediaPath = await _ensureSharedMediaFromUrl(
      url: url,
      filename: filename,
    );

    // 2) 학생 폴더 준비 + 미디어 해시
    final mediaHash = await _sha1OfFile(sharedMediaPath);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));

    // 3-A) 캐시 내 *.xsc → 학생 폴더로 이관
    await _migrateCacheXscIfExists(
      cacheMediaPath: sharedMediaPath,
      studentDir: studentDir,
    );

    // 3-B) 학생 폴더에 미디어 배치 (초회는 복사 고정)
    final linkedOrCopiedMedia = await _placeMediaForStudent(
      sharedMediaPath: sharedMediaPath,
      studentMediaDir: studentDir,
      forceCopy: true, // 초회 copy 고정
    );

    // 4) 원격 최신 current.xsc 우선 시도
    await _downloadLatestXscIfAny(
      studentId: studentId,
      mediaHash: mediaHash,
      intoDir: studentDir,
    );

    // 5) 로컬 최신 xsc 스캔
    final localXsc = await _findLocalLatestXsc(studentDir);

    // 6) 열기 (xsc 우선)
    final toOpen = localXsc ?? linkedOrCopiedMedia;
    await _file.openLocal(toOpen);

    // 7) 저장 감시 & 업로드
    await _watchAndSyncXsc(
      dir: studentDir,
      studentId: studentId,
      mediaHash: mediaHash,
    );
  }

  Future<void> open({
    required ResourceFile resource,
    required String studentId,
  }) async {
    try {
      await StudentService().attachMeToStudent(studentId);
    } catch (_) {}
    // 0) XSC 대상 여부
    final isMedia = isMediaEligibleForXsc(resource);

    if (!isMedia) {
      final url = await _res.signedUrl(resource);
      await _file.openUrl(url);
      return;
    }

    // 1) 공유 미디어 캐시 확보
    final sharedMediaPath = await _ensureSharedMedia(resource);

    // 2) 학생 폴더 생성
    final mediaHash = await _sha1OfFile(sharedMediaPath);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));

    // 3-A) 캐시에 생긴 *.xsc가 있으면 학생 폴더로 이관
    await _migrateCacheXscIfExists(
      cacheMediaPath: sharedMediaPath,
      studentDir: studentDir,
    );

    // 3-B) 학생 폴더에 미디어 배치
    final hasAnyXsc = (await _findLocalLatestXsc(studentDir)) != null;
    final linkedOrCopiedMedia = await _placeMediaForStudent(
      sharedMediaPath: sharedMediaPath,
      studentMediaDir: studentDir,
      // Windows에서는 항상 copy, macOS는 로컬 xsc 없으면 copy 고정
      forceCopy: Platform.isWindows || !hasAnyXsc,
    );

    // 4) 원격 최신 current.xsc 우선 시도
    await _downloadLatestXscIfAny(
      studentId: studentId,
      mediaHash: mediaHash,
      intoDir: studentDir,
    );

    // 5) 로컬 최신 xsc 스캔
    final localXsc = await _findLocalLatestXsc(studentDir);

    // 6) 기본앱 실행 (xsc 우선)
    final toOpen = localXsc ?? linkedOrCopiedMedia;
    await _file.openLocal(toOpen);

    // 7) 저장 감시 시작
    await _watchAndSyncXsc(
      dir: studentDir,
      studentId: studentId,
      mediaHash: mediaHash,
    );
  }

  // ---------------- Pre-open helpers ----------------

  /// 공유 미디어를 로컬 캐시에 보장 (contentHash/index.json 활용)
  Future<String> _ensureSharedMedia(ResourceFile resource) async {
    final cacheRoot = await _ensureDir(p.join(_workspace(), '.shared_cache'));
    final indexPath = p.join(cacheRoot, 'index.json');
    Map<String, dynamic> index = await _readJsonFile(indexPath);

    String? hash = resource.contentHash?.trim().isNotEmpty == true
        ? resource.contentHash!.trim().toLowerCase()
        : null;

    final key = '${resource.storageBucket}/${resource.storagePath}';
    if (hash == null || hash.isEmpty) {
      final entry = index[key];
      if (entry is Map && entry['hash'] is String) {
        hash = (entry['hash'] as String).toLowerCase();
      }
    }

    if (hash != null && hash.isNotEmpty) {
      final hashDir = await _ensureDir(p.join(cacheRoot, hash));
      final outPath = p.join(hashDir, resource.filename);
      final outFile = File(outPath);
      if (await outFile.exists()) return outPath;

      final bytes = await _downloadBytes(await _res.signedUrl(resource));
      await outFile.writeAsBytes(bytes, flush: true);
      index[key] = {
        'hash': hash,
        'filename': resource.filename,
        'updated_at': DateTime.now().toIso8601String(),
      };
      await _writeJsonFile(indexPath, index);
      return outPath;
    }

    // 해시가 전혀 없으면 다운로드 → 해시 산출 → 캐시 보관
    final tmp = await FileService.saveBytesFile(
      filename: resource.filename,
      bytes: await _downloadBytes(await _res.signedUrl(resource)),
    );
    final computedHash = await _sha1OfFile(tmp.path);
    final hashDir = await _ensureDir(p.join(cacheRoot, computedHash));
    final outPath = p.join(hashDir, resource.filename);
    final out = File(outPath);
    if (!await out.exists()) {
      await File(tmp.path).copy(outPath);
    }
    index[key] = {
      'hash': computedHash,
      'filename': resource.filename,
      'updated_at': DateTime.now().toIso8601String(),
    };
    await _writeJsonFile(indexPath, index);
    return outPath;
  }

  // [ADD] 외부/서명 URL 기반 공유 미디어 캐시 확보
  Future<String> _ensureSharedMediaFromUrl({
    required String url,
    required String filename,
  }) async {
    final cacheRoot = await _ensureDir(p.join(_workspace(), '.shared_cache'));

    // 1) 내려받아 임시 해시 계산
    final tmp = await FileService.saveBytesFile(
      filename: filename,
      bytes: await _downloadBytes(url),
    );
    final computedHash = await _sha1OfFile(tmp.path);

    // 2) 캐시에 이동/복사
    final hashDir = await _ensureDir(p.join(cacheRoot, computedHash));
    final outPath = p.join(hashDir, filename);
    final out = File(outPath);
    if (!await out.exists()) {
      await File(tmp.path).copy(outPath);
    } else {
      // 이미 있으면 임시파일은 정리
      try {
        await File(tmp.path).delete();
      } catch (_) {}
    }
    return outPath;
  }

  /// 캐시 폴더(.shared_cache/`<hash>`/)에 생긴 *.xsc를 학생 폴더로 이동
  Future<String?> _migrateCacheXscIfExists({
    required String cacheMediaPath,
    required String studentDir,
  }) async {
    try {
      final cacheDir = p.dirname(cacheMediaPath);
      final d = Directory(cacheDir);
      if (!await d.exists()) return null;
      final xs = await d
          .list(followLinks: true)
          .where((e) => e is File && e.path.toLowerCase().endsWith('.xsc'))
          .cast<File>()
          .toList();
      if (xs.isEmpty) return null;

      // 최신 수정일 우선
      xs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      final src = xs.first;
      final dst = File(p.join(studentDir, p.basename(src.path)));
      try {
        await src.rename(dst.path);
      } catch (_) {
        await src.copy(dst.path);
        try {
          await src.delete();
        } catch (_) {}
      }
      return dst.path;
    } catch (_) {
      return null;
    }
  }

  /// 학생 폴더에 미디어 배치: forceCopy=true면 복사, false면 symlink 시도→실패 시 복사
  Future<String> _placeMediaForStudent({
    required String sharedMediaPath,
    required String studentMediaDir,
    required bool forceCopy,
  }) async {
    final dst = p.join(studentMediaDir, p.basename(sharedMediaPath));
    // Windows는 항상 copy (권한/정책으로 symlink 실패가 잦음)
    if (forceCopy || Platform.isWindows) {
      final copied = await File(sharedMediaPath).copy(dst);
      return copied.path;
    }
    try {
      if (await Link(dst).exists()) return dst;
      await Link(dst).create(sharedMediaPath, recursive: true);
      return dst;
    } catch (_) {
      final copied = await File(sharedMediaPath).copy(dst);
      return copied.path;
    }
  }

    Future<Uint8List> _downloadBytes(String url) async {
    final http = HttpClient();
    final uri = Uri.parse(url);

    // 연결/요청
    final rq = await http.getUrl(uri);

    // (가볍게) 헤더에서 Content-Length=0 감지 시 즉시 차단
    // (일부 서버는 HEAD가 아니면 정확하지 않을 수 있으나 흔한 오류 케이스를 빠르게 컷)
    final clen = rq.headers.value(HttpHeaders.contentLengthHeader);
    if (clen != null) {
      final n = int.tryParse(clen);
      if (n != null && n == 0) {
        throw StateError('미디어 다운로드 실패(빈 응답: Content-Length=0)');
      }
    }

    final rs = await rq.close();

    if (rs.statusCode != 200) {
      throw StateError('미디어 다운로드 실패(${rs.statusCode})');
    }

    final bytes = await rs.fold<List<int>>([], (a, b) => a..addAll(b));

    // 수신 바이트가 0이면 실패로 처리 (캐시/파일 생성 방지)
    if (bytes.isEmpty) {
      throw StateError('미디어 다운로드 실패(빈 응답 바디)');
    }

    return Uint8List.fromList(bytes);
  }


  Future<String> _sha1OfFile(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    return sha1.convert(bytes).toString();
  }

  String _workspace() {
    final home = Platform.environment['HOME'];
    final userProfile = Platform.environment['USERPROFILE'];
    final candidates = <String>[
      if (_wsDir.isNotEmpty) _wsDir,
      Platform.environment['WORKSPACE_DIR'] ?? '',
      if (home != null && home.isNotEmpty) p.join(home, 'GuitarTreeWorkspace'),
      if (userProfile != null && userProfile.isNotEmpty)
        p.join(userProfile, 'GuitarTreeWorkspace'),
      p.join(Directory.systemTemp.path, 'GuitarTreeWorkspace'),
    ].where((e) => e.trim().isNotEmpty).toList();

    for (final c in candidates) {
      try {
        final d = Directory(c);
        if (!d.existsSync()) d.createSync(recursive: true);
        final probe = File(p.join(d.path, '.gt_write_test'));
        probe.writeAsStringSync('ok', flush: true);
        probe.deleteSync();
        return d.path;
      } catch (_) {}
    }
    return Directory.systemTemp.createTempSync('GuitarTreeWorkspace_').path;
  }

  Future<String> _ensureStudentRoot(String studentId) async =>
      _ensureDir(p.join(_workspace(), studentId));

  Future<String> _ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  // ---------------- XSC 다운로드/스캔 ----------------
  Future<String?> _downloadLatestXscIfAny({
    required String studentId,
    required String mediaHash,
    required String intoDir,
  }) async {
    try {
      final prefix = '$studentId/$mediaHash/';
      final store = _sb.storage.from(studentXscBucket);

      final objsRaw = await store.list(
        path: prefix,
        searchOptions: const SearchOptions(limit: 200),
      );
      final List<dynamic> objsDyn = objsRaw;
      if (objsDyn.isEmpty) {
        return null;
      }

      DateTime parseTime(dynamic v) {
        if (v is DateTime) return v;
        if (v is String) {
          return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
        }
         return DateTime.fromMillisecondsSinceEpoch(0);
       }

      String asString(dynamic v) => (v ?? '').toString();

      objsDyn.sort(
        (a, b) => parseTime(b.updatedAt).compareTo(parseTime(a.updatedAt)),
      );


      dynamic current = objsDyn.firstWhere(
        (o) => (o.name as String).toLowerCase() == 'current.xsc',
        orElse: () => objsDyn.first,
      );

      final key = '$prefix${current.name}';
      final bytes = await store.download(key);
      final local = File(p.join(intoDir, 'current.xsc'));
      await local.writeAsBytes(bytes, flush: true);

      // sidecar meta 저장
      final metaPath = p.join(intoDir, '.current.xsc.meta.json');
      final meta = <String, dynamic>{
        'remote_key': key,
        'updated_at': parseTime(current.updatedAt).toIso8601String(),
        'etag': asString(current.eTag ?? current.id),
        'saved_at': DateTime.now().toIso8601String(),
      };
      await _writeJsonFile(metaPath, meta);
      return local.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findLocalLatestXsc(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) return null;
      final xs = await d
          .list(followLinks: true)
          .where((e) => e is File && e.path.toLowerCase().endsWith('.xsc'))
          .cast<File>()
          .toList();
      if (xs.isEmpty) return null;
      xs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return xs.first.path;
    } catch (_) {
      return null;
    }
  }

  // ---------------- Watch & upload (충돌 체크 포함) ----------------
  Future<void> _watchAndSyncXsc({
    required String dir,
    required String studentId,
    required String mediaHash,
  }) async {
    await disposeWatcher();
    final folder = Directory(dir);
    if (!await folder.exists()) return;

    final Map<String, Timer> debounces = {};
    final Map<String, bool> busy = {};

    bool isTempOrHidden(String path) {
      final name = p.basename(path).toLowerCase();
      if (name.startsWith('.')) return true;
      if (name.endsWith('~')) return true;
      if (name.endsWith('.tmp')) return true;
      if (name.startsWith('~\$')) return true;
      if (name.startsWith('.sb-')) return true;
      return false;
    }

    Future<Map<String, dynamic>> readSidecarMeta() async =>
        _readJsonFile(p.join(dir, '.current.xsc.meta.json'));

    Future<void> writeSidecarMetaFromRemote(dynamic remoteObj) async {
      try {
        final metaPath = p.join(dir, '.current.xsc.meta.json');
        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        String asString(dynamic v) => (v ?? '').toString();

        final meta = <String, dynamic>{
          'remote_key': '$studentId/$mediaHash/current.xsc',
          'updated_at': toTime(remoteObj?.updatedAt).toIso8601String(),
          'etag': asString(remoteObj?.eTag ?? remoteObj?.id),
          'saved_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(metaPath, meta);
      } catch (_) {}
    }

    Future<dynamic> findRemoteCurrentMeta() async {
      try {
        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';
        final objs = await store.list(
          path: prefix,
          searchOptions: const SearchOptions(limit: 50),
        );
        for (final o in objs) {
          if (o.name.toString().toLowerCase() == 'current.xsc') return o;
        }
      } catch (_) {}
      return null;
    }

    Future<void> uploadOnce(String path) async {
      if (busy[path] == true) {
        return;
      }
      busy[path] = true;
      try {
        // 파일 크기 안정화 대기
        final f = File(path);
        var last = -1;
        for (int i = 0; i < 16; i++) {
          final len = await f.length();
          if (last == len) break;
          last = len;
          await Future.delayed(const Duration(milliseconds: 200));
        }

        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';

        // 0) 충돌 감지
        final remote = await findRemoteCurrentMeta();
        final sidecar = await readSidecarMeta();

        bool conflict = false;
        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        String asString(dynamic v) => (v ?? '').toString();

        final String remoteUpdated = toTime(
          remote?.updatedAt,
        ).toIso8601String();
        final String remoteEtag = asString(remote?.eTag ?? remote?.id);


        final localBaseUpdated = sidecar['updated_at']?.toString();
        final localBaseEtag = sidecar['etag']?.toString();

        if (remote != null) {
          if ((localBaseUpdated != null && remoteUpdated != localBaseUpdated) ||
              (remoteEtag.isNotEmpty && (localBaseEtag ?? '').isNotEmpty && remoteEtag != localBaseEtag)) {
            conflict = true;
          }
        }

        // 1) 항상 백업
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        final backupKey =
            '${prefix}backups/$ts${conflict ? '-branch' : ''}.xsc';
        await store.upload(
          backupKey,
          f,
          fileOptions: const FileOptions(upsert: false),
        );

        // 2) 충돌이면 current는 덮지 않음 → 마커 생성
        if (conflict) {
          final marker = File(p.join(dir, '.xsc_conflict'));
          try {
            await marker.writeAsString(
              'conflict at $ts (remote changed since last download)',
              flush: true,
            );
          } catch (_) {}
          if (remote != null) {
            await writeSidecarMetaFromRemote(remote);
          }
          return;
        }

        // 3) 정상 교체
        final curKey = '${prefix}current.xsc';
        await store.upload(
          curKey,
          f,
          fileOptions: const FileOptions(upsert: true),
        );

        // 메타 갱신
        final after = await findRemoteCurrentMeta();
        if (after != null) await writeSidecarMetaFromRemote(after);

        // NOTE: 기존 API 시그니처 호환 (매개변수명은 mp3Hash였지만 의미는 "미디어 해시")
        await LessonLinksService().touchXscUpdatedAt(
          studentId: studentId,
          mp3Hash: mediaHash,
        );
        await LessonLinksService().upsertAttachmentXscMeta(
          studentId: studentId,
          mp3Hash: mediaHash,
          xscStoragePath: 'student_xsc/$studentId/$mediaHash/current.xsc',
        );
      } catch (_) {
      } finally {
        busy[path] = false;
      }
    }

    void scheduleUpload(String path) {
      final name = path.toLowerCase();
      if (name.endsWith('.xsc') == false) {
        return;
      }
      if (isTempOrHidden(path)) {
        return;
      }

      debounces[path]?.cancel();
      debounces[path] = Timer(
        const Duration(milliseconds: 800),
        () => unawaited(uploadOnce(path)),
      );
    }

    _sub = folder
        .watch(
          events:
              FileSystemEvent.create |
              FileSystemEvent.modify |
              FileSystemEvent.move,
          recursive: false,
        )
        .listen((evt) => scheduleUpload(evt.path.toString()));
  }
}
