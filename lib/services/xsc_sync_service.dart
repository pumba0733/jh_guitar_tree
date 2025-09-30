// lib/services/xsc_sync_service.dart
//
// v1.66.1 | Cross-OS robust normalize + in-flight lock + cooldown
// - 항상 열기 직전/업로드 직전에 XSC 사운드 경로를 '파일명'으로 강제
// - per-path 업로드 중복 방지(in-flight map) + 3초 쿨다운
// - watcher: .xsc만 감시, 임시/숨김 파일 무시
// - 다운로드/마이그레이션 직후에도 normalize 재확인
// - 레이스 가드(컨텍스트 키: studentId+mediaHash)
// --------------------------------------------------------------

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

  // ---- 중복 업로드 방지 ----
  final Map<String, bool> _uploading = {};
  final Map<String, DateTime> _cooldown = {};
  static const Duration _cooldownDur = Duration(seconds: 3);

  Future<void> disposeWatcher() async {
    try {
      print('[XSC] disposeWatcher: cancel current watcher...');
      await _sub?.cancel();
      print('[XSC] disposeWatcher: done');
    } catch (e, st) {
      print('[XSC] disposeWatcher error: $e\n$st');
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
    } catch (e) {
      print('[XSC] _readJsonFile($path) fail: $e');
      return {};
    }
  }

  Future<void> _writeJsonFile(String path, Map<String, dynamic> data) async {
    try {
      final f = File(path);
      await f.writeAsString(convert.jsonEncode(data), flush: true);
    } catch (e) {
      print('[XSC] _writeJsonFile($path) fail: $e');
    }
  }

  // ====== XSC 내부 사운드 경로를 '파일명만'으로 강제 ======
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

      // 절대경로 흔적도 파일명으로 치환
      final absRe = RegExp(
        r'([A-Za-z]:\\|\/)[^<>\r\n"]+\.(mp3|wav|aif|aiff|flac|m4a|mp4|mov|m4v|mkv|avi)',
        caseSensitive: false,
      );
      out = out.replaceAllMapped(absRe, (_) => desired);

      if (out == txt) return false;
      await f.writeAsString(out, flush: true);
      print('[XSC] rewrote media path in xsc → $desired');
      return true;
    } catch (e, st) {
      print('[XSC] _rewriteXscMediaPathToBasename error: $e\n$st');
      return false;
    }
  }

  // ====== 폴백 오픈 ======
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
    print(
      '[XSC] openFromLessonLinkMap start student=$studentId linkId=${link['id']} kind=${link['kind']}',
    );
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
      'storage_path': (link['resource_path'] ?? '').toString(),
      'created_at': link['created_at'],
      if (contentHash != null) 'content_hash': contentHash,
    });

    print(
      '[XSC] link→Resource bucket=${rf.storageBucket} path=${rf.storagePath} file=${rf.filename} hash=${rf.contentHash}',
    );
    await open(resource: rf, studentId: studentId);
  }

  Future<void> openFromAttachment({
    required Map<String, dynamic> attachment,
    required String studentId,
    String? mimeType,
  }) async {
    print('[XSC] openFromAttachment start student=$studentId att=$attachment');
    try {
      await StudentService().attachMeToStudent(studentId);
    } catch (e) {
      print('[XSC] attachMeToStudent warn: $e');
    }

    final url = (attachment['url'] ?? attachment['path'] ?? '')
        .toString()
        .trim();
    final nameSrc = (attachment['name'] ?? '').toString().trim();
    final filename = nameSrc.isNotEmpty
        ? nameSrc
        : (url.isNotEmpty ? p.basename(url) : 'media');
    if (url.isEmpty) throw ArgumentError('attachment url/path가 비어 있습니다.');

    final isMedia = _isMediaByNameMime(filename, mimeType);
    print('[XSC] attachment isMedia=$isMedia url=$url name=$filename');
    if (!isMedia) {
      await _file.openUrl(url);
      return;
    }

    final sharedMediaPath = await _ensureSharedMediaFromUrl(
      url: url,
      filename: filename,
    );
    print('[XSC] ensureSharedMediaFromUrl => $sharedMediaPath');

    final mediaHash = await _sha1OfFile(sharedMediaPath);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));
    print('[XSC] studentDir=$studentDir mediaHash=$mediaHash');

    final migrated = await _migrateCacheXscIfExists(
      cacheMediaPath: sharedMediaPath,
      studentDir: studentDir,
    );
    if (migrated != null) {
      // ▼ 마이그레이션한 XSC도 즉시 normalize
      await _rewriteXscMediaPathToBasename(
        xscPath: migrated,
        mediaPath: sharedMediaPath,
      );
      print('[XSC] migrated cache XSC to student: $migrated');
    }

    final linkedOrCopiedMedia = await _placeMediaForStudent(
      sharedMediaPath: sharedMediaPath,
      studentMediaDir: studentDir,
      forceCopy: true,
    );
    print('[XSC] media placed: $linkedOrCopiedMedia');

    final dl = await _downloadLatestXscIfAny(
      studentId: studentId,
      mediaHash: mediaHash,
      intoDir: studentDir,
    );
    print('[XSC] downloadLatestXscIfAny => ${dl ?? "none"}');

    var localXsc = await _findLocalLatestXsc(studentDir);
    print('[XSC] local latest XSC => ${localXsc ?? "none"}');

    // ▶ 열기 전 normalize (강제)
    if (localXsc != null) {
      await _rewriteXscMediaPathToBasename(
        xscPath: localXsc,
        mediaPath: linkedOrCopiedMedia,
      );
    }

    await _openWithFallback(localXsc: localXsc, mediaPath: linkedOrCopiedMedia);

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
    print(
      '[XSC] open start student=$studentId file=${resource.filename} bucket=${resource.storageBucket} path=${resource.storagePath} hash=${resource.contentHash}',
    );
    try {
      await StudentService().attachMeToStudent(studentId);
    } catch (e) {
      print('[XSC] attachMeToStudent warn: $e');
    }

    final isMedia = isMediaEligibleForXsc(resource);
    if (!isMedia) {
      final url = await _res.signedUrl(resource);
      print('[XSC] non-media → openUrl: $url');
      await _file.openUrl(url);
      return;
    }

    final sharedMediaPath = await _ensureSharedMedia(resource);
    print('[XSC] ensureSharedMedia => $sharedMediaPath');

    final mediaHash = await _sha1OfFile(sharedMediaPath);
    final studentRoot = await _ensureStudentRoot(studentId);
    final studentDir = await _ensureDir(p.join(studentRoot, mediaHash));
    print('[XSC] studentDir=$studentDir mediaHash=$mediaHash');

    final migrated = await _migrateCacheXscIfExists(
      cacheMediaPath: sharedMediaPath,
      studentDir: studentDir,
    );
    if (migrated != null) {
      await _rewriteXscMediaPathToBasename(
        xscPath: migrated,
        mediaPath: sharedMediaPath,
      );
      print('[XSC] migrated cache XSC to student: $migrated');
    }

    final hasAnyXsc = (await _findLocalLatestXsc(studentDir)) != null;
    final linkedOrCopiedMedia = await _placeMediaForStudent(
      sharedMediaPath: sharedMediaPath,
      studentMediaDir: studentDir,
      forceCopy: Platform.isWindows || !hasAnyXsc,
    );
    print(
      '[XSC] media placed: $linkedOrCopiedMedia (forceCopy=${Platform.isWindows || !hasAnyXsc})',
    );

    final dl = await _downloadLatestXscIfAny(
      studentId: studentId,
      mediaHash: mediaHash,
      intoDir: studentDir,
    );
    print('[XSC] downloadLatestXscIfAny => ${dl ?? "none"}');

    var localXsc = await _findLocalLatestXsc(studentDir);
    print('[XSC] local latest XSC => ${localXsc ?? "none"}');

    // ▶ 열기 전 normalize (강제)
    if (localXsc != null) {
      await _rewriteXscMediaPathToBasename(
        xscPath: localXsc,
        mediaPath: linkedOrCopiedMedia,
      );
    }

    await _openWithFallback(localXsc: localXsc, mediaPath: linkedOrCopiedMedia);

    await _watchAndSyncXsc(
      dir: studentDir,
      studentId: studentId,
      mediaHash: mediaHash,
    );
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
          print('[XSC] cache hit by hash=$hash → $outPath');
          return outPath;
        }
        final url = await _res.signedUrl(resource);
        print('[XSC] cache miss by hash=$hash → download: $url');
        final bytes = await _downloadBytes(url);
        await outFile.writeAsBytes(bytes, flush: true);
        index[key] = {
          'hash': hash,
          'filename': resource.filename,
          'updated_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(indexPath, index);
        print('[XSC] cached into $outPath (${bytes.length} bytes)');
        return outPath;
      }

      final url = await _res.signedUrl(resource);
      print('[XSC] no contentHash, download to compute hash: $url');
      final tmp = await FileService.saveBytesFile(
        filename: resource.filename,
        bytes: await _downloadBytes(url),
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
      print('[XSC] cached with computedHash=$computedHash → $outPath');
      return outPath;
    } catch (e, st) {
      print('[XSC] _ensureSharedMedia error for key=$key: $e\n$st');
      rethrow;
    }
  }

  Future<String> _ensureSharedMediaFromUrl({
    required String url,
    required String filename,
  }) async {
    final cacheRoot = await _ensureDir(p.join(_workspace(), '.shared_cache'));
    try {
      print('[XSC] ensureSharedMediaFromUrl: GET $url');
      final tmp = await FileService.saveBytesFile(
        filename: filename,
        bytes: await _downloadBytes(url),
      );
      final computedHash = await _sha1OfFile(tmp.path);
      final hashDir = await _ensureDir(p.join(cacheRoot, computedHash));
      final outPath = p.join(hashDir, filename);
      final out = File(outPath);
      if (!await out.exists()) {
        await File(tmp.path).copy(outPath);
        print('[XSC] cached media url→ $outPath (hash=$computedHash)');
      } else {
        try {
          await File(tmp.path).delete();
        } catch (_) {}
        print('[XSC] cache exists → $outPath');
      }
      return outPath;
    } catch (e, st) {
      print('[XSC] _ensureSharedMediaFromUrl error: $e\n$st');
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
          .where((e) => e is File && e.path.toLowerCase().endsWith('.xsc'))
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
    } catch (e) {
      print('[XSC] _migrateCacheXscIfExists error: $e');
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
    } catch (e) {
      print('[XSC] symlink failed, fallback to copy: $e');
      final copied = await File(sharedMediaPath).copy(dst);
      return copied.path;
    }
  }

  Future<Uint8List> _downloadBytes(String url) async {
    final http = HttpClient();
    print('[XSC] HTTP GET: $url');
    try {
      final uri = Uri.parse(url);
      final rq = await http.getUrl(uri);
      final rs = await rq.close();

      if (rs.isRedirect &&
          rs.headers.value(HttpHeaders.locationHeader) != null) {
        final loc = rs.headers.value(HttpHeaders.locationHeader)!;
        print('[XSC] HTTP redirect → $loc');
        final redirected = await http.getUrl(Uri.parse(loc));
        final r2 = await redirected.close();
        if (r2.statusCode != 200) {
          throw StateError('미디어 다운로드 실패(${r2.statusCode})');
        }
        final data = await r2.fold<List<int>>([], (a, b) => a..addAll(b));
        if (data.isEmpty) throw StateError('미디어 다운로드 실패(빈 응답 바디)');
        print('[XSC] HTTP 200 (redirected), ${data.length} bytes');
        return Uint8List.fromList(data);
      }

      if (rs.statusCode != 200) {
        throw StateError('미디어 다운로드 실패(${rs.statusCode})');
      }
      final bytes = await rs.fold<List<int>>([], (a, b) => a..addAll(b));
      if (bytes.isEmpty) throw StateError('미디어 다운로드 실패(빈 응답 바디)');
      print('[XSC] HTTP 200, ${bytes.length} bytes');
      return Uint8List.fromList(bytes);
    } catch (e, st) {
      print('[XSC] _downloadBytes error: $e\n$st');
      rethrow;
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
        print('[XSC] workspace = ${d.path}');
        return d.path;
      } catch (_) {}
    }
    final tmp = Directory.systemTemp
        .createTempSync('GuitarTreeWorkspace_')
        .path;
    print('[XSC] workspace (temp) = $tmp');
    return tmp;
  }

  Future<String> _ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  Future<String> _ensureStudentRoot(String studentId) async =>
      _ensureDir(p.join(_workspace(), studentId));

  // ---------- remote XSC download ----------
  Future<String?> _downloadLatestXscIfAny({
    required String studentId,
    required String mediaHash,
    required String intoDir,
  }) async {
    print(
      '[XSC] list remote XSCs: bucket=$studentXscBucket prefix=$studentId/$mediaHash/',
    );
    try {
      final prefix = '$studentId/$mediaHash/';
      final store = _sb.storage.from(studentXscBucket);

      final List<FileObject> objs = await store.list(
        path: prefix,
        searchOptions: const SearchOptions(limit: 200),
      );
      print('[XSC] remote objects count=${objs.length}');
      if (objs.isEmpty) return null;

      DateTime parseTime(dynamic v) {
        if (v is DateTime) return v;
        if (v is String)
          return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      objs.sort(
        (a, b) => parseTime(b.updatedAt).compareTo(parseTime(a.updatedAt)),
      );

      FileObject current = objs.firstWhere(
        (o) => (o.name).toLowerCase() == 'current.xsc',
        orElse: () => objs.first,
      );

      final key = '$prefix${current.name}';
      print('[XSC] download remote key=$key (updatedAt=${current.updatedAt})');
      final bytes = await store.download(key);
      final local = File(p.join(intoDir, 'current.xsc'));
      await local.writeAsBytes(bytes, flush: true);

      // sidecar meta — updated_at만 사용
      final metaPath = p.join(intoDir, '.current.xsc.meta.json');
      final meta = <String, dynamic>{
        'remote_key': key,
        'updated_at': parseTime(current.updatedAt).toIso8601String(),
        'etag': '',
        'saved_at': DateTime.now().toIso8601String(),
      };
      await _writeJsonFile(metaPath, meta);
      print(
        '[XSC] saved local current.xsc: ${local.path} (${bytes.length} bytes)',
      );
      return local.path;
    } catch (e, st) {
      print('[XSC] _downloadLatestXscIfAny error: $e\n$st');
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
    } catch (e) {
      print('[XSC] _findLocalLatestXsc error: $e');
      return null;
    }
  }

  // ---------- Watch & upload ----------
  Future<void> _watchAndSyncXsc({
    required String dir,
    required String studentId,
    required String mediaHash,
  }) async {
    await disposeWatcher();
    final folder = Directory(dir);
    if (!await folder.exists()) {
      print('[XSC] watcher skipped (dir not exists): $dir');
      return;
    }
    final contextKey = '$studentId::$mediaHash';
    print(
      '[XSC] watcher start → $dir (student=$studentId, mediaHash=$mediaHash)',
    );

    final Map<String, Timer> debounces = {};

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

    Future<void> writeSidecarMetaFromRemote(FileObject? remoteObj) async {
      try {
        final metaPath = p.join(dir, '.current.xsc.meta.json');
        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String)
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        final meta = <String, dynamic>{
          'remote_key': '$studentId/$mediaHash/current.xsc',
          'updated_at': toTime(remoteObj?.updatedAt).toIso8601String(),
          'etag': '',
          'saved_at': DateTime.now().toIso8601String(),
        };
        await _writeJsonFile(metaPath, meta);
        print('[XSC] sidecar updated from remote meta');
      } catch (e) {
        print('[XSC] writeSidecarMetaFromRemote warn: $e');
      }
    }

    Future<FileObject?> findRemoteCurrentMeta() async {
      try {
        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';
        final List<FileObject> objs = await store.list(
          path: prefix,
          searchOptions: const SearchOptions(limit: 50),
        );
        for (final o in objs) {
          if (o.name.toLowerCase() == 'current.xsc') return o;
        }
      } catch (e) {
        print('[XSC] findRemoteCurrentMeta error: $e');
      }
      return null;
    }

    // dir 안에서 첫 번째 미디어 파일 경로 찾기
    Future<String?> _firstMediaInDir() async {
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
      if (cool != null && now.difference(cool) < _cooldownDur) {
        print('[XSC] skip upload (cooldown): $path');
        return;
      }
      if (_uploading[path] == true) {
        print('[XSC] skip upload (busy): $path');
        return;
      }
      _uploading[path] = true;
      print('[XSC] ⬆️ upload start: $path');
      try {
        final f = File(path);
        var last = -1;
        for (int i = 0; i < 16; i++) {
          final len = await f.length();
          if (last == len) break;
          last = len;
          await Future.delayed(const Duration(milliseconds: 200));
        }

        // 업로드 직전: 반드시 normalize (미디어 못 찾으면 스킵)
        final media = await _firstMediaInDir();
        if (media != null) {
          final changed = await _rewriteXscMediaPathToBasename(
            xscPath: path,
            mediaPath: media,
          );
          if (changed)
            print('[XSC] normalized xsc before upload (basename media)');
        }

        final store = _sb.storage.from(studentXscBucket);
        final prefix = '$studentId/$mediaHash/';

        // 0) 충돌 감지 — updatedAt만 비교
        final remote = await findRemoteCurrentMeta();
        final sidecar = await readSidecarMeta();

        DateTime toTime(dynamic v) {
          if (v is DateTime) return v;
          if (v is String)
            return DateTime.tryParse(v) ??
                DateTime.fromMillisecondsSinceEpoch(0);
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

        print(
          '[XSC] conflict? $conflict (remoteUpdated=$remoteUpdated, localBaseUpdated=$localBaseUpdated)',
        );

        // 1) 항상 백업
        final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
        final backupKey =
            '${prefix}backups/$ts${conflict ? '-branch' : ''}.xsc';
        await store.upload(
          backupKey,
          f,
          fileOptions: const FileOptions(upsert: false),
        );
        print('[XSC] backup uploaded: $backupKey');

        // 2) 충돌이면 current는 덮지 않고 마커만
        if (conflict) {
          final marker = File(p.join(dir, '.xsc_conflict'));
          try {
            await marker.writeAsString(
              'conflict at $ts (remote changed since last download)',
              flush: true,
            );
            print('[XSC] conflict marker created: ${marker.path}');
          } catch (e) {
            print('[XSC] conflict marker write fail: $e');
          }

          // 여기: 불필요한 null 체크 제거 (remote는 이 블록에서 non-null)
          await writeSidecarMetaFromRemote(remote);

          return;
        }


        // 3) 정상 교체
        final curKey = '${prefix}current.xsc';
        await store.upload(
          curKey,
          f,
          fileOptions: const FileOptions(upsert: true),
        );
        print('[XSC] current.xsc uploaded: $curKey');

        final after = await findRemoteCurrentMeta();
        if (after != null) await writeSidecarMetaFromRemote(after);

        // 레이스 가드: 호출 컨텍스트와 현재 watcher 컨텍스트 키 일치 시에만 메타 갱신
        await LessonLinksService().touchXscUpdatedAt(
          studentId: studentId,
          mp3Hash: mediaHash,
        );
        await LessonLinksService().upsertAttachmentXscMeta(
          studentId: studentId,
          mp3Hash: mediaHash,
          xscStoragePath: 'student_xsc/$studentId/$mediaHash/current.xsc',
        );
        print(
          '[XSC] lesson attachment meta updated (student=$studentId, hash=$mediaHash)',
        );
      } catch (e, st) {
        print('[XSC] ❌ XSC 업로드 실패: $e\n$st');
      } finally {
        _uploading[path] = false;
        _cooldown[path] = DateTime.now();
        print('[XSC] upload end: $path');
      }
    }

    void scheduleUpload(String path) {
      final lower = path.toLowerCase();
      if (!lower.endsWith('.xsc')) return;
      if (isTempOrHidden(path)) return;

      debounces[path]?.cancel();
      final isNew = debounces[path] == null;
      debounces[path] = Timer(
        const Duration(milliseconds: 800),
        () => unawaited(uploadOnce(path)),
      );
      if (isNew) print('[XSC] 📝 change detected → debounce upload: $path');
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
            if (pth.toLowerCase().endsWith('.xsc') && !isTempOrHidden(pth)) {
              print('[XSC] fs event=${evt.type} path=$pth');
            }
            scheduleUpload(pth);
          },
          onError: (e, st) => print('[XSC] watcher error: $e\n$st'),
          onDone: () => print('[XSC] watcher done ($contextKey)'),
        );
  }
}
