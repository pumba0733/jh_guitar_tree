// lib/services/xsc_sync_service.dart
// v1.64.1-migrate | Transcribe(xsc) 동기화
// - 초회(로컬 xsc 없음)에는 공유 mp3를 학생 폴더에 "복사"로 배치 → 저장 위치 고정
// - .shared_cache/<hash>/ 에 생성된 *.xsc 자동 이관(학생 폴더로 move) 후 그 파일로 오픈
// - 캐시 최적화 / 업로드 충돌 체크 / sidecar 메타 저장 로직은 이전 버전 유지

import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' as convert;
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
    final kind = (link['kind'] ?? '').toString();
    if (kind != 'resource') {
      throw ArgumentError('resource 링크가 아닙니다.');
    }
    final contentHash =
        (link['resource_content_hash'] ?? link['content_hash'] ?? link['hash'])
            ?.toString();

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
      if (contentHash != null) 'content_hash': contentHash,
    });
    await open(resource: rf, studentId: studentId);
  }

  Future<void> open({
    required ResourceFile resource,
    required String studentId,
  }) async {
    final isAudioMp3 =
        resource.filename.toLowerCase().endsWith('.mp3') ||
        (resource.mimeType?.contains('audio') ?? false);

    if (!isAudioMp3) {
      final url = await _res.signedUrl(resource);
      await _file.openUrl(url);
      return;
    }

    // 1) 공유 mp3 캐시 확보
    final sharedMp3Path = await _ensureSharedMp3(resource);

    // 2) 학생 폴더 생성
    final mp3Hash = await _sha1OfFile(sharedMp3Path);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mp3Hash));

    // 3-A) 캐시에 생긴 *.xsc가 있으면 학생 폴더로 이관
    String? localXsc = await _migrateCacheXscIfExists(
      cacheMp3Path: sharedMp3Path,
      studentDir: studentDir,
    );

    // 3-B) 학생 폴더에 mp3 배치
    //     로컬 xsc가 "아직" 없으면 '복사'로 강제(저장 위치 고정), 있으면 '심볼릭 링크'
    final linkedOrCopiedMp3 = await _placeMp3ForStudent(
      sharedMp3Path: sharedMp3Path,
      studentMp3Dir: studentDir,
      forceCopy: localXsc == null, // 초회엔 copy
    );

    // 4) 원격 최신 xsc 내려받기(없을 때만 로컬 스캔/이관으로 결정)
    localXsc ??= await _downloadLatestXscIfAny(
      studentId: studentId,
      mp3Hash: mp3Hash,
      intoDir: studentDir,
    );

    // 4-b) 그래도 없으면 로컬 학생 폴더 스캔(임의 파일명)
    localXsc ??= await _findLocalLatestXsc(studentDir);

    // 5) 기본앱 실행 (xsc 우선)
    final toOpen = localXsc ?? linkedOrCopiedMp3;
    await _file.openLocal(toOpen);

    // 6) 저장 감시 시작 (충돌 체크 포함)
    await _watchAndSyncXsc(
      dir: studentDir,
      studentId: studentId,
      mp3Hash: mp3Hash,
    );
  }

  // ---------------- Pre-open helpers ----------------

  /// 공유 mp3를 로컬 캐시에 보장 (contentHash/index.json 활용)
  Future<String> _ensureSharedMp3(ResourceFile resource) async {
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

  /// 캐시 폴더(.shared_cache/<hash>/)에 생긴 *.xsc를 학생 폴더로 이동
  Future<String?> _migrateCacheXscIfExists({
    required String cacheMp3Path,
    required String studentDir,
  }) async {
    try {
      final cacheDir = p.dirname(cacheMp3Path);
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
      // move(동일 볼륨) 또는 copy 후 삭제
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

  /// 학생 폴더에 mp3 배치: forceCopy=true면 복사, false면 symlink 시도→실패 시 복사
  Future<String> _placeMp3ForStudent({
    required String sharedMp3Path,
    required String studentMp3Dir,
    required bool forceCopy,
  }) async {
    final dst = p.join(studentMp3Dir, p.basename(sharedMp3Path));
    if (forceCopy) {
      final copied = await File(sharedMp3Path).copy(dst);
      return copied.path;
    }
    // 심볼릭 링크 시도
    try {
      if (await Link(dst).exists()) return dst;
      await Link(dst).create(sharedMp3Path, recursive: true);
      return dst;
    } catch (_) {
      final copied = await File(sharedMp3Path).copy(dst);
      return copied.path;
    }
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
    return sha1.convert(bytes).toString();
  }

  String _workspace() {
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      if (_wsDir.isNotEmpty) _wsDir,
      Platform.environment['WORKSPACE_DIR'] ?? '',
      if (home != null && home.isNotEmpty) p.join(home, 'GuitarTreeWorkspace'),
      p.join(Directory.systemTemp.path, 'GuitarTreeWorkspace'),
    ].where((e) => e.trim().isNotEmpty).toList();

    for (final c in candidates) {
      try {
        final d = Directory(c);
        if (!d.existsSync()) d.createSync(recursive: true);
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
    required String mp3Hash,
    required String intoDir,
  }) async {
    try {
      final prefix = '$studentId/$mp3Hash/';
      final store = _sb.storage.from(studentXscBucket);

      final objsRaw = await store.list(
        path: prefix,
        searchOptions: const SearchOptions(limit: 200),
      );
      final List<dynamic> objsDyn = objsRaw;
      if (objsDyn.isEmpty) return null;

      objsDyn.sort((a, b) {
        DateTime parse(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) return DateTime.tryParse(v) ?? DateTime(1970);
          return DateTime(1970);
        }

        return parse(b.updatedAt).compareTo(parse(a.updatedAt));
      });

      dynamic current = objsDyn.firstWhere(
        (o) => (o.name as String).toLowerCase() == 'current.xsc',
        orElse: () => objsDyn.first,
      );

      final key = '$prefix${current.name as String}';
      final bytes = await store.download(key);
      final local = File(p.join(intoDir, 'current.xsc'));
      await local.writeAsBytes(bytes, flush: true);

      // sidecar meta 저장
      final metaPath = p.join(intoDir, '.current.xsc.meta.json');
      final meta = <String, dynamic>{
        'remote_key': key,
        'updated_at': (current.updatedAt is DateTime)
            ? (current.updatedAt as DateTime).toIso8601String()
            : current.updatedAt?.toString(),
        'etag': (current.eTag ?? current.id ?? '').toString(),
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
    required String mp3Hash,
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

    Future<Map<String, dynamic>> _readSidecarMeta() async =>
        _readJsonFile(p.join(dir, '.current.xsc.meta.json'));

    Future<void> _writeSidecarMetaFromRemote(dynamic remoteObj) async {
      try {
        final metaPath = p.join(dir, '.current.xsc.meta.json');
        final meta = <String, dynamic>{
          'remote_key': remoteObj?.id?.toString() ?? '',
          'updated_at': (remoteObj?.updatedAt is DateTime)
              ? (remoteObj.updatedAt as DateTime).toIso8601String()
              : remoteObj?.updatedAt?.toString(),
          'etag': (remoteObj?.eTag ?? remoteObj?.id ?? '').toString(),
          'saved_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(metaPath, meta);
      } catch (_) {}
    }

    Future<dynamic> _findRemoteCurrentMeta() async {
      try {
        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mp3Hash/';
        final objs = await store.list(
          path: prefix,
          searchOptions: const SearchOptions(limit: 50),
        );
        for (final o in objs) {
          if ((o.name as String).toLowerCase() == 'current.xsc') return o;
        }
      } catch (_) {}
      return null;
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

        // 0) 충돌 감지
        final remote = await _findRemoteCurrentMeta();
        final sidecar = await _readSidecarMeta();

        bool conflict = false;
        String? remoteUpdated = (remote?.updatedAt is DateTime)
            ? (remote.updatedAt as DateTime).toIso8601String()
            : remote?.updatedAt?.toString();
        final remoteEtag = (remote?.eTag ?? remote?.id ?? '').toString();

        final localBaseUpdated = sidecar['updated_at']?.toString();
        final localBaseEtag = sidecar['etag']?.toString();

        if (remote != null) {
          if ((remoteUpdated != null &&
                  localBaseUpdated != null &&
                  remoteUpdated != localBaseUpdated) ||
              (remoteEtag.isNotEmpty &&
                  localBaseEtag != null &&
                  localBaseEtag.isNotEmpty &&
                  remoteEtag != localBaseEtag)) {
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
            await _writeSidecarMetaFromRemote(remote);
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
        final after = await _findRemoteCurrentMeta();
        if (after != null) await _writeSidecarMetaFromRemote(after);

        await LessonLinksService().touchXscUpdatedAt(
          studentId: studentId,
          mp3Hash: mp3Hash,
        );
      } catch (_) {
      } finally {
        busy[path] = false;
      }
    }

    void scheduleUpload(String path) {
      if (isTempOrHidden(path)) return;
      if (!path.toLowerCase().endsWith('.xsc')) return;
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
