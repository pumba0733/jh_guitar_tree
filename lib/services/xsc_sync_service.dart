// lib/services/xsc_sync_service.dart
//
// v1.83 | XSC/GTXSC dual support + resilient sync
// - NEW: .gtxsc 동기화(다운로드/감시/업로드/백업) 추가
// - CHANGE: 최신본 선택 규칙 = current.gtxsc > current.xsc > updated_at 최신
// - CHANGE: sidecar 메타 파일을 확장자별로 분리(.current.<ext>.meta.json)
// - CHANGE: lesson_links 갱신 시 실제 확장자 반영 (current.<ext>)
// - KEEP: 기존 .xsc 동작/흐름 100% 유지
//
// v1.66.1+stabilize 기반: retry/silence 유지

import 'dart:async' as async; // zone, retry, timers
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

  async.StreamSubscription<FileSystemEvent>? _sub;

  // ---- 업로드 쿨다운/중복 방지 ----
  final Map<String, bool> _uploading = {};
  final Map<String, DateTime> _cooldown = {};
  static const Duration _cooldownDur = Duration(seconds: 3);

  // ---- 지원 확장자(.xsc, .gtxsc) ----
  static const List<String> _xscExts = ['.xsc', '.gtxsc'];

  // ===== 안정화 유틸: 지수 백오프 공통 래퍼 =====
  Future<T> _withRetry<T>(
    Future<T> Function() task, {
    int retries = 3,
    Duration base = const Duration(milliseconds: 300),
    Duration timeout = const Duration(seconds: 20),
    bool Function(Object e)? shouldRetry,
  }) async {
    int attempt = 0;
    while (true) {
      try {
        return await task().timeout(timeout);
      } on async.TimeoutException {
        if (attempt >= retries) rethrow;
      } catch (e) {
        final s = e.toString();
        final retry =
            (shouldRetry?.call(e) ?? false) ||
            e is SocketException ||
            e is HttpException ||
            e is async.TimeoutException ||
            s.contains('ENETUNREACH') ||
            s.contains('Connection closed') ||
            s.contains('temporarily unavailable') ||
            s.contains('504') ||
            s.contains('503') ||
            s.contains('502') ||
            s.contains('429');
        if (!retry || attempt >= retries) rethrow;
      }
      attempt++;
      final wait = base * (1 << (attempt - 1));
      await async.Future.delayed(wait);
    }
  }

  // ===== 로그 무음 실행 =====
  Future<T> _silencePrints<T>(Future<T> Function() task) {
    return async.runZoned(
      task,
      zoneSpecification: async.ZoneSpecification(
        print: (self, parent, zone, message) {
          /* no-op */
        },
      ),
    );
  }

  Future<void> disposeWatcher() async {
    try {
      await _sub?.cancel();
    } catch (_) {
    } finally {
      _sub = null;
    }
  }

  // ---------- helpers ----------
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

  bool isMediaEligibleForXsc(ResourceFile r) =>
      _isMediaByNameMime(r.filename, r.mimeType);

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

  // ====== XSC/GTXSC 내부 사운드 경로를 '파일명만'으로 강제 ======
  Future<bool> _rewriteXscMediaPathToBasename({
    required String xscPath,
    required String mediaPath,
  }) async {
    try {
      final f = File(xscPath);
      if (!await f.exists()) return false;
      final txt = await f.readAsString();
      final desired = p.basename(mediaPath);

      String fixTag(String s, String tag) {
        final re = RegExp(
          '<\\s*$tag\\s*>\\s*(.*?)\\s*<\\s*/\\s*$tag\\s*>',
          caseSensitive: false,
          dotAll: true,
        );
        return s.replaceAllMapped(re, (m) {
          final cur = (m.group(1) ?? '').trim();
          if (cur == desired) return m.group(0)!;
          return '<$tag>$desired</$tag>';
        });
      }

      var out = txt;
      for (final tag in const [
        'soundfile',
        'soundfilename',
        'mediafile',
        'audiofile',
      ]) {
        out = fixTag(out, tag);
      }

      final absRe = RegExp(
        r'([A-Za-z]:\\|\/)[^<>\r\n"]+\.(mp3|wav|aif|aiff|flac|m4a|mp4|mov|m4v|mkv|avi)',
        caseSensitive: false,
      );
      out = out.replaceAllMapped(absRe, (_) => desired);

      if (out == txt) return false;
      await f.writeAsString(out, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openWithFallback({
    required String? localXsc,
    required String mediaPath,
  }) async {
    if (localXsc != null && await File(localXsc).exists()) {
      await _file.openLocal(localXsc);
      return;
    }
    await _file.openLocal(mediaPath);
  }

  // ========= public entrypoints =========
  Future<void> openFromLessonLinkMap({
    required Map<String, dynamic> link,
    required String studentId,
  }) async {
    await _silencePrints(() async {
      if ((link['kind'] ?? '').toString() != 'resource') {
        throw ArgumentError('resource 링크가 아닙니다.');
      }
      final contentHash =
          (link['resource_content_hash'] ??
                  link['content_hash'] ??
                  link['hash'])
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
        'storage_path': (link['resource_path'] ?? '').toString(),
        'created_at': link['created_at'],
        if (contentHash != null) 'content_hash': contentHash,
      });
      await open(resource: rf, studentId: studentId);
    });
  }

  Future<void> openFromAttachment({
    required Map<String, dynamic> attachment,
    required String studentId,
    String? mimeType,
  }) async {
    await _silencePrints(() async {
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
      if (url.isEmpty) throw ArgumentError('attachment url/path가 비어 있습니다.');

      final isMedia = _isMediaByNameMime(filename, mimeType);
      if (!isMedia) {
        await _file.openUrl(url);
        return;
      }

      final sharedMediaPath = await _ensureSharedMediaFromUrl(
        url: url,
        filename: filename,
      );

      final mediaHash = await _sha1OfFile(sharedMediaPath);
      final studentRoot = await _ensureStudentRoot(studentId);
      final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));

      final migrated = await _migrateCacheXscIfExists(
        cacheMediaPath: sharedMediaPath,
        studentDir: studentDir,
      );
      if (migrated != null) {
        await _rewriteXscMediaPathToBasename(
          xscPath: migrated,
          mediaPath: sharedMediaPath,
        );
      }

      final linkedOrCopiedMedia = await _placeMediaForStudent(
        sharedMediaPath: sharedMediaPath,
        studentMediaDir: studentDir,
        forceCopy: true, // Windows 강제 복사
      );

      await _downloadLatestSidecarIfAny(
        studentId: studentId,
        mediaHash: mediaHash,
        intoDir: studentDir,
      );

      var localXsc = await _findLocalLatestSidecar(studentDir);
      if (localXsc != null) {
        await _rewriteXscMediaPathToBasename(
          xscPath: localXsc,
          mediaPath: linkedOrCopiedMedia,
        );
      }

      await _openWithFallback(
        localXsc: localXsc,
        mediaPath: linkedOrCopiedMedia,
      );

      await _watchAndSyncSidecar(
        dir: studentDir,
        studentId: studentId,
        mediaHash: mediaHash,
      );
    });
  }

  Future<void> open({
    required ResourceFile resource,
    required String studentId,
  }) async {
    await _silencePrints(() async {
      try {
        await StudentService().attachMeToStudent(studentId);
      } catch (_) {}
      final isMedia = isMediaEligibleForXsc(resource);
      if (!isMedia) {
        final url = await _res.signedUrl(resource);
        await _file.openUrl(url);
        return;
      }

      final sharedMediaPath = await _ensureSharedMedia(resource);
      final mediaHash = await _sha1OfFile(sharedMediaPath);
      final studentRoot = await _ensureStudentRoot(studentId);
      final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));

      final migrated = await _migrateCacheXscIfExists(
        cacheMediaPath: sharedMediaPath,
        studentDir: studentDir,
      );
      if (migrated != null) {
        await _rewriteXscMediaPathToBasename(
          xscPath: migrated,
          mediaPath: sharedMediaPath,
        );
      }

      final hasAny = (await _findLocalLatestSidecar(studentDir)) != null;
      final linkedOrCopiedMedia = await _placeMediaForStudent(
        sharedMediaPath: sharedMediaPath,
        studentMediaDir: studentDir,
        forceCopy: Platform.isWindows || !hasAny,
      );

      await _downloadLatestSidecarIfAny(
        studentId: studentId,
        mediaHash: mediaHash,
        intoDir: studentDir,
      );

      var localSidecar = await _findLocalLatestSidecar(studentDir);
      if (localSidecar != null) {
        await _rewriteXscMediaPathToBasename(
          xscPath: localSidecar,
          mediaPath: linkedOrCopiedMedia,
        );
      }

      await _openWithFallback(
        localXsc: localSidecar,
        mediaPath: linkedOrCopiedMedia,
      );

      await _watchAndSyncSidecar(
        dir: studentDir,
        studentId: studentId,
        mediaHash: mediaHash,
      );
    });
  }

  // ---------- cache/shared ----------
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

    try {
      if (hash != null && hash.isNotEmpty) {
        final hashDir = await _ensureDir(p.join(cacheRoot, hash));
        final outPath = p.join(hashDir, resource.filename);
        final outFile = File(outPath);
        if (await outFile.exists()) {
          return outPath;
        }
        final url = await _res.signedUrl(resource);
        final bytes = await _withRetry(() => _downloadBytes(url));
        await outFile.writeAsBytes(bytes, flush: true);
        index[key] = {
          'hash': hash,
          'filename': resource.filename,
          'updated_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(indexPath, index);
        return outPath;
      }

      final url = await _res.signedUrl(resource);
      final tmp = await FileService.saveBytesFile(
        filename: resource.filename,
        bytes: await _withRetry(() => _downloadBytes(url)),
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
    } catch (e) {
      rethrow;
    }
  }

  Future<String> _ensureSharedMediaFromUrl({
    required String url,
    required String filename,
  }) async {
    final cacheRoot = await _ensureDir(p.join(_workspace(), '.shared_cache'));
    try {
      final tmp = await FileService.saveBytesFile(
        filename: filename,
        bytes: await _withRetry(() => _downloadBytes(url)),
      );
      final computedHash = await _sha1OfFile(tmp.path);
      final hashDir = await _ensureDir(p.join(cacheRoot, computedHash));
      final outPath = p.join(hashDir, filename);
      final out = File(outPath);
      if (!await out.exists()) {
        await File(tmp.path).copy(outPath);
      } else {
        try {
          await File(tmp.path).delete();
        } catch (_) {}
      }
      return outPath;
    } catch (e) {
      rethrow;
    }
  }

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
          .where(
            (e) =>
                e is File &&
                _xscExts.any((ext) => e.path.toLowerCase().endsWith(ext)),
          )
          .cast<File>()
          .toList();
      if (xs.isEmpty) return null;

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

  Future<String> _placeMediaForStudent({
    required String sharedMediaPath,
    required String studentMediaDir,
    required bool forceCopy,
  }) async {
    final dst = p.join(studentMediaDir, p.basename(sharedMediaPath));
    if (forceCopy || Platform.isWindows) {
      final copied = await File(sharedMediaPath).copy(dst);
      return copied.path;
    }
    try {
      if (await File(dst).exists() || await Link(dst).exists()) return dst;
      await Link(dst).create(sharedMediaPath, recursive: true);
      return dst;
    } catch (_) {
      final copied = await File(sharedMediaPath).copy(dst);
      return copied.path;
    }
  }

  Future<Uint8List> _downloadBytes(String url) async {
    final http = HttpClient();
    try {
      final uri = Uri.parse(url);
      final rq = await http.getUrl(uri);
      final rs = await rq.close();

      if (rs.isRedirect &&
          rs.headers.value(HttpHeaders.locationHeader) != null) {
        final loc = rs.headers.value(HttpHeaders.locationHeader)!;
        final redirected = await http.getUrl(Uri.parse(loc));
        final r2 = await redirected.close();
        if (r2.statusCode != 200) {
          throw StateError('미디어 다운로드 실패(${r2.statusCode})');
        }
        final data = await r2.fold<List<int>>([], (a, b) => a..addAll(b));
        if (data.isEmpty) throw StateError('미디어 다운로드 실패(빈 응답 바디)');
        return Uint8List.fromList(data);
      }

      if (rs.statusCode != 200) {
        throw StateError('미디어 다운로드 실패(${rs.statusCode})');
      }
      final bytes = await rs.fold<List<int>>([], (a, b) => a..addAll(b));
      if (bytes.isEmpty) throw StateError('미디어 다운로드 실패(빈 응답 바디)');
      return Uint8List.fromList(bytes);
    } finally {
      try {
        http.close(force: true);
      } catch (_) {}
    }
  }

  Future<String> _sha1OfFile(String path) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    final h = sha1.convert(bytes).toString();
    return h;
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
    final tmp = Directory.systemTemp
        .createTempSync('GuitarTreeWorkspace_')
        .path;
    return tmp;
  }

  Future<String> _ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  Future<String> _ensureStudentRoot(String studentId) async =>
      _ensureDir(p.join(_workspace(), studentId));

  // ---------- Remote sidecar download (xsc/gtxsc) ----------
  Future<String?> _downloadLatestSidecarIfAny({
    required String studentId,
    required String mediaHash,
    required String intoDir,
  }) async {
    return _silencePrints(() async {
      try {
        final prefix = '$studentId/$mediaHash/';
        final store = _sb.storage.from(studentXscBucket);

        final List<FileObject> objs = await _withRetry(
          () => store.list(
            path: prefix,
            searchOptions: const SearchOptions(limit: 200),
          ),
        );
        if (objs.isEmpty) return null;

        DateTime parseTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        // 1) 우선순위: current.gtxsc > current.xsc
        FileObject? pick;
        for (final cand in ['current.gtxsc', 'current.xsc']) {
          try {
            pick = objs.firstWhere((o) => o.name.toLowerCase() == cand);
            if (pick != null) break;
          } catch (_) {}
        }

        // 2) 없으면 updated_at 최신
        objs.sort(
          (a, b) => parseTime(b.updatedAt).compareTo(parseTime(a.updatedAt)),
        );
        pick ??= objs.first;

        final key = '$prefix${pick!.name}';
        final bytes = await _withRetry(() => store.download(key));

        final ext = p.extension(pick!.name).toLowerCase();
        final local = File(p.join(intoDir, 'current$ext'));
        await local.writeAsBytes(bytes, flush: true);

        // sidecar meta — updated_at만 사용
        final metaPath = p.join(intoDir, '.current$ext.meta.json');
        final meta = <String, dynamic>{
          'remote_key': key,
          'updated_at': parseTime(pick!.updatedAt).toIso8601String(),
          'etag': '',
          'saved_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(metaPath, meta);
        return local.path;
      } catch (_) {
        return null;
      }
    });
  }

  Future<String?> _findLocalLatestSidecar(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) return null;
      final xs = await d
          .list(followLinks: true)
          .where(
            (e) =>
                e is File &&
                _xscExts.any((ext) => e.path.toLowerCase().endsWith(ext)),
          )
          .cast<File>()
          .toList();
      if (xs.isEmpty) return null;
      xs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return xs.first.path;
    } catch (_) {
      return null;
    }
  }

  // ---------- Watch & upload (xsc/gtxsc) ----------
  Future<void> _watchAndSyncSidecar({
    required String dir,
    required String studentId,
    required String mediaHash,
  }) async {
    await disposeWatcher();
    final folder = Directory(dir);
    if (!await folder.exists()) return;

    final Map<String, async.Timer> debounces = {};

    bool isTempOrHidden(String path) {
      final name = p.basename(path).toLowerCase();
      if (name.startsWith('.')) return true;
      if (name.endsWith('~')) return true;
      if (name.endsWith('.tmp')) return true;
      if (name.startsWith('~\$')) return true;
      if (name.startsWith('.sb-')) return true;
      return false;
    }

    String _sidecarMetaPath(String ext) =>
        p.join(dir, '.current$ext.meta.json');

    Future<Map<String, dynamic>> readSidecarMeta(String ext) async =>
        _readJsonFile(_sidecarMetaPath(ext));

    Future<void> writeSidecarMetaFromRemote(
      FileObject? remoteObj,
      String ext,
    ) async {
      try {
        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        final meta = <String, dynamic>{
          'remote_key': '$studentId/$mediaHash/current$ext',
          'updated_at': toTime(remoteObj?.updatedAt).toIso8601String(),
          'etag': '',
          'saved_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(_sidecarMetaPath(ext), meta);
      } catch (_) {}
    }

    Future<FileObject?> findRemoteCurrentMeta(String ext) async {
      try {
        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';
        final List<FileObject> objs = await _withRetry(
          () => store.list(
            path: prefix,
            searchOptions: const SearchOptions(limit: 50),
          ),
        );
        for (final o in objs) {
          if (o.name.toLowerCase() == 'current$ext') return o;
        }
      } catch (_) {}
      return null;
    }

    // dir 안에서 첫 번째 미디어 파일 찾기
    Future<String?> firstMediaInDir() async {
      try {
        final dd = Directory(dir);
        final f = await dd
            .list(followLinks: true)
            .where((e) => e is File)
            .cast<File>()
            .firstWhere((ff) {
              final nm = ff.path.toLowerCase();
              return nm.endsWith('.mp3') ||
                  nm.endsWith('.wav') ||
                  nm.endsWith('.aiff') ||
                  nm.endsWith('.aif') ||
                  nm.endsWith('.flac') ||
                  nm.endsWith('.m4a') ||
                  nm.endsWith('.mp4') ||
                  nm.endsWith('.mov') ||
                  nm.endsWith('.m4v') ||
                  nm.endsWith('.mkv') ||
                  nm.endsWith('.avi');
            }, orElse: () => File(''));
        if (await f.exists()) return f.path;
      } catch (_) {}
      return null;
    }

    Future<void> uploadOnce(String path) async {
      final now = DateTime.now();
      final cool = _cooldown[path];
      if (cool != null && now.difference(cool) < _cooldownDur) return;
      if (_uploading[path] == true) return;

      final String ext = p.extension(path).toLowerCase();
      if (!_xscExts.contains(ext)) return;

      _uploading[path] = true;
      try {
        final f = File(path);
        var last = -1;
        for (int i = 0; i < 16; i++) {
          final len = await f.length();
          if (last == len) break;
          last = len;
          await async.Future.delayed(const Duration(milliseconds: 200));
        }

        // 업로드 직전 normalize (미디어 없으면 스킵 아님)
        final media = await firstMediaInDir();
        if (media != null) {
          await _rewriteXscMediaPathToBasename(xscPath: path, mediaPath: media);
        }

        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';

        // 0) 충돌 감지 — sidecar별로 updatedAt 비교
        final remote = await findRemoteCurrentMeta(ext);
        final sidecar = await readSidecarMeta(ext);

        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String) {
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          }
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        final String remoteUpdated = toTime(
          remote?.updatedAt,
        ).toIso8601String();
        final String? localBaseUpdated = sidecar['updated_at']?.toString();

        final bool conflict =
            remote != null &&
            localBaseUpdated != null &&
            remoteUpdated != localBaseUpdated;

        // 1) 항상 백업 (확장자 맞춰 저장)
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        final backupKey =
            '${prefix}backups/$ts${conflict ? '-branch' : ''}$ext';

        await _withRetry(
          () => store.upload(
            backupKey,
            f,
            fileOptions: const FileOptions(upsert: false),
          ),
        );

        // 2) 충돌이면 current는 덮지 않고 마커만
        if (conflict) {
          final marker = File(p.join(dir, '.xsc_conflict'));
          try {
            await marker.writeAsString(
              'conflict at $ts (remote changed since last download)',
              flush: true,
            );
          } catch (_) {}
          await writeSidecarMetaFromRemote(remote, ext);
          return;
        }

        // 3) 정상 교체 (upsert to current.<ext>)
        final curKey = '${prefix}current$ext';
        await _withRetry(
          () => store.upload(
            curKey,
            f,
            fileOptions: const FileOptions(upsert: true),
          ),
        );

        final after = await findRemoteCurrentMeta(ext);
        if (after != null) await writeSidecarMetaFromRemote(after, ext);

        // lesson_links 메타 갱신 (실제 확장자 반영)
        await LessonLinksService().touchXscUpdatedAt(
          studentId: studentId,
          mp3Hash: mediaHash,
        );
        await LessonLinksService().upsertAttachmentXscMeta(
          studentId: studentId,
          mp3Hash: mediaHash,
          xscStoragePath: 'student_xsc/$studentId/$mediaHash/current$ext',
        );
      } catch (_) {
        // silent
      } finally {
        _uploading[path] = false;
        _cooldown[path] = DateTime.now();
      }
    }

    void scheduleUpload(String path) {
      final lower = path.toLowerCase();
      final isSidecar = _xscExts.any((e) => lower.endsWith(e));
      if (!isSidecar) return;
      if (isTempOrHidden(path)) return;

      debounces[path]?.cancel();
      debounces[path] = async.Timer(
        const Duration(milliseconds: 800),
        () => async.unawaited(uploadOnce(path)),
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
        .listen(
          (evt) {
            final pth = evt.path.toString();
            scheduleUpload(pth);
          },
          onError: (_) {},
          onDone: () {},
        );
  }
   // ===== Built-in player 준비 /감시 진입점 =====
  // 미디어/사이드카를 로컬에 준비만 하고 열지는 않음.
  // 반환: 로컬 학생 폴더/미디어 경로/사이드카 경로/해시
  Future<PreparedPlayback> prepareForBuiltInPlayer({
    required ResourceFile resource,
    required String studentId,
  }) async {
    await _silencePrints(() async {
      try { await StudentService().attachMeToStudent(studentId); } catch (_) {}
    });

    final sharedMediaPath = await _ensureSharedMedia(resource);
    final mediaHash = await _sha1OfFile(sharedMediaPath);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));

    final migrated = await _migrateCacheXscIfExists(
      cacheMediaPath: sharedMediaPath,
      studentDir: studentDir,
    );
    if (migrated != null) {
      await _rewriteXscMediaPathToBasename(
        xscPath: migrated,
        mediaPath: sharedMediaPath,
      );
    }

    final hasAny = (await _findLocalLatestSidecar(studentDir)) != null;
    final linkedOrCopiedMedia = await _placeMediaForStudent(
      sharedMediaPath: sharedMediaPath,
      studentMediaDir: studentDir,
      forceCopy: Platform.isWindows || !hasAny,
    );

    await _downloadLatestSidecarIfAny(
      studentId: studentId,
      mediaHash: mediaHash,
      intoDir: studentDir,
    );

    final localSidecar = await _findLocalLatestSidecar(studentDir);
    if (localSidecar != null) {
      await _rewriteXscMediaPathToBasename(
        xscPath: localSidecar,
        mediaPath: linkedOrCopiedMedia,
      );
    }

    return PreparedPlayback(
      studentId: studentId,
      mediaHash: mediaHash,
      studentDir: studentDir,
      mediaPath: linkedOrCopiedMedia,
      sidecarPath: localSidecar,
    );
  }

  // 내장 플레이어가 떠 있는 동안, 해당 폴더 감시/업로드를 시작
  Future<void> startWatcherForBuiltIn(PreparedPlayback prep) async {
    await _watchAndSyncSidecar(
      dir: prep.studentDir,
      studentId: prep.studentId,
      mediaHash: prep.mediaHash,
    );
  }
}

// ===== DTO =====
class PreparedPlayback {
  final String studentId;
  final String mediaHash;
  final String studentDir;
  final String mediaPath;
  final String? sidecarPath;

  PreparedPlayback({
    required this.studentId,
    required this.mediaHash,
    required this.studentDir,
    required this.mediaPath,
    required this.sidecarPath,
  });
}
