// lib/services/file_service.dart
// v1.67 | 리소스 첨부 UX 정리
// - NEW: attachXFilesAsResourcesForTodayLesson(...) 추가 (드래그&드롭 대응용)
// - FIX: HttpClient close 처리로 리소스 릭 방지
// - 기존 v1.66 API 호환 유지

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, consolidateHttpClientResponseBytes;
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../supabase/supabase_tables.dart';

import '../models/resource.dart';
import './resource_service.dart';
import './lesson_links_service.dart';

class FileService {
  FileService._();
  static final FileService instance = FileService._();
  factory FileService() => instance;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  SupabaseClient get _sb => Supabase.instance.client;

  // (구) 레슨 첨부 버킷 (드래그 구경로 유지용 – 새 플로우는 리소스 업로드)
  static const String _bucketName = SupabaseBuckets.lessonAttachments;

  // ========= Workspace =========
  static const String _envWorkspaceDir = String.fromEnvironment(
    'WORKSPACE_DIR',
    defaultValue: '',
  );

  static Directory _homeDir() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return Directory(home);
  }

  static Future<Directory> _downloadsRoot() async {
    try {
      if (_isDesktop) {
        final d = await getDownloadsDirectory();
        if (d != null) return d;
      }
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  static String _normalizeWorkspacePath(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return v;

    final homePath = _homeDir().path;

    if (v.startsWith('~')) {
      v = p.join(homePath, v.substring(1));
    }
    if (v.startsWith('/Users/you/')) {
      final tail = v.substring('/Users/you/'.length);
      v = p.join('/Users', p.basename(homePath), tail);
    }
    return v;
  }

  static Future<Directory> _resolveWorkspaceDir() async {
    final envRaw = _envWorkspaceDir;
    if (envRaw.isNotEmpty) {
      final fixed = _normalizeWorkspacePath(envRaw);
      try {
        final d = Directory(fixed);
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      } catch (_) {
        final dl = await _downloadsRoot();
        final fb = Directory(p.join(dl.path, 'GuitarTreeWorkspace'));
        if (!await fb.exists()) await fb.create(recursive: true);
        return fb;
      }
    }

    final home = _homeDir().path;
    final def = Directory(p.join(home, 'GuitarTreeWorkspace'));
    try {
      if (!await def.exists()) await def.create(recursive: true);
      return def;
    } catch (_) {
      final dl = await _downloadsRoot();
      final fb = Directory(p.join(dl.path, 'GuitarTreeWorkspace'));
      if (!await fb.exists()) await fb.create(recursive: true);
      return fb;
    }
  }

  static Future<Directory> _studentWorkspaceDir(String studentId) async {
    final root = await _resolveWorkspaceDir();
    final d = Directory(p.join(root.path, studentId));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> _ensureDir(String dirPath) async {
    final d = Directory(dirPath);
    if (!await d.exists()) await d.create(recursive: true);
    return;
  }

  // ===== 재시도 유틸 =====
  Future<T> _retry<T>(
    Future<T> Function() task, {
    int maxAttempts = 3,
    Duration baseDelay = const Duration(milliseconds: 250),
    Duration timeout = const Duration(seconds: 15),
    bool Function(Object e)? shouldRetry,
  }) async {
    int attempt = 0;
    Object? lastError;
    while (attempt < maxAttempts) {
      attempt++;
      try {
        return await task().timeout(timeout);
      } on TimeoutException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
        final retry = shouldRetry?.call(e) ?? _defaultShouldRetry(e);
        if (!retry || attempt >= maxAttempts) rethrow;
      }
      if (attempt < maxAttempts) {
        final wait = baseDelay * (1 << (attempt - 1));
        await Future.delayed(wait);
      }
    }
    throw lastError ?? StateError('알 수 없는 네트워크 오류');
  }

  bool _defaultShouldRetry(Object e) {
    final s = e.toString();
    return e is SocketException ||
        e is HttpException ||
        e is TimeoutException ||
        s.contains('ENETUNREACH') ||
        s.contains('Connection closed') ||
        s.contains('temporarily unavailable') ||
        s.contains('503') ||
        s.contains('502') ||
        s.contains('429');
  }

  String _displaySafeName(String raw) {
    final ext = p.extension(raw);
    final base = p.basenameWithoutExtension(raw);
    final sanitizedBase = base
        .replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_')
        .trim();
    final finalBase = sanitizedBase.isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : sanitizedBase;
    return '$finalBase$ext';
  }

  String _keySafeName(String raw) {
    final ext = p.extension(raw);
    var base = p.basenameWithoutExtension(raw);
    base = base.replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_');
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    base = base.replaceAll(RegExp(r'_+'), '_').trim();
    if (base.isEmpty) {
      base = DateTime.now().millisecondsSinceEpoch.toString();
    }
    var safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (safeExt.length > 10) safeExt = safeExt.substring(0, 10);
    return '$base$safeExt';
  }

  // -----------------------------
  // Downloads helpers
  // -----------------------------
  static Future<Directory> _resolveDownloadsDir() async {
    return _downloadsRoot();
  }

  static Future<File> saveTextFile({
    required String filename,
    required String content,
  }) async {
    final dir = await _resolveDownloadsDir();
    final f = File(p.join(dir.path, filename));
    return f.writeAsString(content);
  }

  static Future<File> saveBytesFile({
    required String filename,
    required List<int> bytes,
  }) async {
    final dir = await _resolveDownloadsDir();
    final f = File(p.join(dir.path, filename));
    return f.writeAsBytes(bytes, flush: true);
  }

  // -----------------------------
  // 로컬 선택
  // -----------------------------
  Future<List<PlatformFile>> pickLocalFiles({
    List<String>? allowedExtensions,
    bool allowMultiple = true,
  }) async {
    if (!_isDesktop) {
      throw UnsupportedError('이 기능은 데스크탑에서만 지원됩니다.');
    }
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
      withReadStream: true,
      withData: true,
      dialogTitle: '첨부할 파일을 선택하세요',
    );
    if (result == null) return const [];
    return result.files;
  }

  // -----------------------------
  // (구) lesson_attachments 업로드 API (사용 지양)
  // -----------------------------
  Future<Map<String, dynamic>> uploadXFile({
    required XFile xfile,
    required String studentId,
    required String dateStr,
  }) async {
    final displayName = xfile.name.isNotEmpty
        ? xfile.name
        : p.basename(xfile.path);
    final tempDir = await getTemporaryDirectory();
    final tmpPath = p.join(tempDir.path, _displaySafeName(displayName));

    if (xfile.path.isNotEmpty) {
      await File(xfile.path).copy(tmpPath);
    } else {
      final bytes = await xfile.readAsBytes();
      await File(tmpPath).writeAsBytes(bytes);
    }

    final uploaded = await uploadPathToStorage(
      absolutePath: tmpPath,
      studentId: studentId,
      dateStr: dateStr,
      originalName: displayName,
    );
    uploaded['localPath'] = tmpPath;
    return uploaded;
  }

  Future<Map<String, dynamic>> uploadPathToStorage({
    required String absolutePath,
    required String studentId,
    required String dateStr, // YYYY-MM-DD
    String? originalName,
  }) async {
    final file = File(absolutePath);
    if (!file.existsSync()) {
      throw ArgumentError('파일을 찾을 수 없습니다: $absolutePath');
    }

    final displayName = originalName ?? p.basename(absolutePath);
    final keyName = _keySafeName(displayName);
    final objectKey = '$studentId/$dateStr/$keyName';
    final bytes = await file.readAsBytes();

    final resolvedMime =
        lookupMimeType(displayName) ?? 'application/octet-stream';

    await _retry(
      () => _sb.storage
          .from(_bucketName)
          .uploadBinary(
            objectKey,
            bytes,
            fileOptions: FileOptions(upsert: true, contentType: resolvedMime),
          ),
    );

    final publicUrl = _sb.storage.from(_bucketName).getPublicUrl(objectKey);
    return {
      'path': objectKey,
      'url': publicUrl,
      'name': displayName,
      'size': bytes.length,
      'mime': resolvedMime,
    };
  }

  Future<Map<String, dynamic>> uploadPickedFile({
    required PlatformFile picked,
    required String studentId,
    required String dateStr,
  }) async {
    final displayName = picked.name.isNotEmpty ? picked.name : 'file';
    final tempDir = await getTemporaryDirectory();
    final tmpPath = p.join(tempDir.path, _displaySafeName(displayName));

    if (picked.path != null) {
      await File(picked.path!).copy(tmpPath);
    } else if (picked.readStream != null) {
      final out = File(tmpPath).openWrite();
      await picked.readStream!.pipe(out);
      await out.flush();
      await out.close();
    } else if (picked.bytes != null) {
      await File(tmpPath).writeAsBytes(picked.bytes!);
    } else {
      throw StateError('파일 데이터를 읽을 수 없습니다: ${picked.name}');
    }

    final uploaded = await uploadPathToStorage(
      absolutePath: tmpPath,
      studentId: studentId,
      dateStr: dateStr,
      originalName: displayName,
    );
    uploaded['localPath'] = tmpPath;
    return uploaded;
  }

  Future<List<Map<String, dynamic>>> pickAndUploadMultiple({
    required String studentId,
    required String dateStr,
    List<String>? allowedExtensions,
  }) async {
    final picked = await pickLocalFiles(
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
    );
    final out = <Map<String, dynamic>>[];
    for (final f in picked) {
      final uploaded = await uploadPickedFile(
        picked: f,
        studentId: studentId,
        dateStr: dateStr,
      );
      out.add(uploaded);
    }
    return out;
  }

  // -----------------------------
  // 신규: '첨부=리소스 업로드 + 오늘레슨 링크' API
  // -----------------------------

  /// 파일 1건을 '공유 리소스(curriculum)'로 업로드 후, 오늘레슨에 즉시 링크
  Future<ResourceFile> attachFileAsResourceForTodayLesson({
    required String studentId,
    required String localPath,
    String? originalFilename,
    String? nodeId,
  }) async {
    final resource = await ResourceService().uploadFromLocalPathAsResource(
      localPath: localPath,
      originalFilename: originalFilename,
      nodeId: nodeId,
    );
    await LessonLinksService().ensureTodayLessonAndLinkResource(
      studentId: studentId,
      resource: resource,
    );
    return resource;
  }

  /// 여러 파일(피커 결과)을 리소스로 업로드 후, 오늘레슨에 모두 링크
  Future<List<ResourceFile>> attachPlatformFilesAsResourcesForTodayLesson({
    required String studentId,
    required List<PlatformFile> files,
    String? nodeId,
  }) async {
    final results = <ResourceFile>[];
    for (final f in files) {
      String? path = f.path;
      String name = f.name;
      String tmpForStream = '';

      if (path == null) {
        final tempDir = await getTemporaryDirectory();
        tmpForStream = p.join(
          tempDir.path,
          _displaySafeName(name.isEmpty ? 'file' : name),
        );
        if (f.readStream != null) {
          final out = File(tmpForStream).openWrite();
          await f.readStream!.pipe(out);
          await out.flush();
          await out.close();
        } else if (f.bytes != null) {
          await File(tmpForStream).writeAsBytes(f.bytes!);
        } else {
          throw StateError('파일 데이터를 읽을 수 없습니다: ${f.name}');
        }
        path = tmpForStream;
      }

      final res = await attachFileAsResourceForTodayLesson(
        studentId: studentId,
        localPath: path,
        originalFilename: name.isNotEmpty ? name : p.basename(path),
        nodeId: nodeId,
      );
      results.add(res);

      if (tmpForStream.isNotEmpty) {
        try {
          await File(tmpForStream).delete();
        } catch (_) {}
      }
    }
    return results;
  }

  /// 파일 피커를 띄워 선택한 파일들을 리소스로 업로드 후 오늘레슨에 링크
  Future<List<ResourceFile>> pickAndAttachAsResourcesForTodayLesson({
    required String studentId,
    String? nodeId,
  }) async {
    final picked = await pickLocalFiles(
      allowMultiple: true,
      allowedExtensions: null,
    );
    if (picked.isEmpty) return const [];
    return await attachPlatformFilesAsResourcesForTodayLesson(
      studentId: studentId,
      files: picked,
      nodeId: nodeId,
    );
  }

  /// (NEW) 드래그&드롭 XFile 리스트 → 리소스 업로드 + 오늘레슨 링크
  Future<List<ResourceFile>> attachXFilesAsResourcesForTodayLesson({
    required String studentId,
    required List<XFile> xfiles,
    String? nodeId,
  }) async {
    final results = <ResourceFile>[];
    for (final xf in xfiles) {
      final local = (xf.path.isNotEmpty)
          ? xf.path
          : await _writeTempFromXFile(xf);
      final res = await attachFileAsResourceForTodayLesson(
        studentId: studentId,
        localPath: local,
        originalFilename: (xf.name.isNotEmpty ? xf.name : p.basename(local)),
        nodeId: nodeId,
      );
      results.add(res);
    }
    return results;
  }

  Future<String> _writeTempFromXFile(XFile xf) async {
    final tempDir = await getTemporaryDirectory();
    final tmpPath = p.join(
      tempDir.path,
      _displaySafeName(xf.name.isNotEmpty ? xf.name : 'file'),
    );
    final bytes = await xf.readAsBytes();
    await File(tmpPath).writeAsBytes(bytes, flush: true);
    return tmpPath;
  }

  // -----------------------------
  // 열기(기본앱 고정)
  // -----------------------------
  Future<void> openLocal(String absolutePath) async {
    if (!_isDesktop) {
      throw UnsupportedError('기본 앱 열기는 데스크탑에서만 지원됩니다.');
    }
    final r = await OpenFilex.open(absolutePath);
    if (r.type != ResultType.done) {
      throw StateError('기본 앱으로 열 수 없습니다: ${r.message}');
    }
  }

  Future<void> openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) throw StateError('URL을 열 수 없습니다: $url');
  }

  Future<void> openSmart({String? path, String? url, String? name}) async {
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      await openLocal(path);
      return;
    }
    if (url == null || url.isEmpty) {
      throw ArgumentError('openSmart: path 또는 url 중 하나가 필요합니다.');
    }
    final local = await _ensureLocalCopy({
      'url': url,
      'name': name ?? p.basename(Uri.parse(url).path),
    });
    await openLocal(local);
  }

  String? _extractStorageKeyFromUrl(String url) {
    const patterns = <String>[
      '/object/public/',
      '/object/sign/',
      '/object/auth/',
    ];
    for (final prefix in patterns) {
      final idx = url.indexOf(prefix);
      if (idx >= 0) {
        final sub = url.substring(idx + prefix.length);
        final pathPart = sub.split('?').first;
        final parts = pathPart.split('/');
        if (parts.isEmpty) return null;
        if (parts.first == _bucketName) {
          return parts.skip(1).join('/');
        }
      }
    }
    return null;
  }

  Future<Uint8List> _downloadUrlToBytes(String url) async {
    final key = _extractStorageKeyFromUrl(url);
    if (key != null) {
      return await _retry(() => _sb.storage.from(_bucketName).download(key));
    }
    final client = HttpClient();
    try {
      final res = await _retry<HttpClientResponse>(
        () => client.getUrl(Uri.parse(url)).then((rq) => rq.close()),
      );
      if (res.statusCode != 200) {
        throw StateError('파일 다운로드 실패(HTTP ${res.statusCode})');
      }
      final data = await consolidateHttpClientResponseBytes(res);
      return Uint8List.fromList(data);
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  Future<String> _ensureLocalCopy(Map<String, dynamic> att) async {
    final existing = (att['localPath'] ?? '').toString();
    if (existing.isNotEmpty && File(existing).existsSync()) {
      return existing;
    }

    Uint8List bytes;
    String fallbackName;

    final url = (att['url'] ?? '').toString();
    if (url.isNotEmpty) {
      final key = _extractStorageKeyFromUrl(url);
      if (key != null) {
        bytes = await _retry(() => _sb.storage.from(_bucketName).download(key));
        fallbackName = p.basename(key);
      } else {
        final client = HttpClient();
        try {
          final res = await _retry<HttpClientResponse>(
            () => client.getUrl(Uri.parse(url)).then((rq) => rq.close()),
          );
          if (res.statusCode != 200) {
            throw StateError('파일 다운로드 실패(HTTP ${res.statusCode})');
          }
          bytes = Uint8List.fromList(
            await consolidateHttpClientResponseBytes(res),
          );
          fallbackName = p.basename(Uri.parse(url).path);
        } finally {
          try {
            client.close(force: true);
          } catch (_) {}
        }
      }
    } else {
      final path = (att['path'] ?? '').toString();
      if (path.isEmpty) throw ArgumentError('열 수 있는 경로/URL이 없습니다.');
      bytes = await _retry(() => _sb.storage.from(_bucketName).download(path));
      fallbackName = p.basename(path);
    }

    final tempDir = await getTemporaryDirectory();
    final fname = _displaySafeName(att['name']?.toString() ?? fallbackName);
    final outPath = p.join(tempDir.path, fname);
    await File(outPath).writeAsBytes(bytes);
    att['localPath'] = outPath;
    return outPath;
  }

  Future<void> openAttachment(Map<String, dynamic> att) async {
    final local = await _ensureLocalCopy(att);
    await openLocal(local);
  }

  // -----------------------------
  // 다운로드(영구 저장)
  // -----------------------------
  Future<String> saveAttachmentToDownloads(Map<String, dynamic> att) async {
    final local = await _ensureLocalCopy(att);
    final bytes = await File(local).readAsBytes();
    final dir = await _resolveDownloadsDir();
    final outName = _displaySafeName(
      att['name']?.toString() ?? p.basename(local),
    );
    final outPath = _avoidNameClash(dir.path, outName);
    await File(outPath).writeAsBytes(bytes);
    return outPath;
  }

  Future<void> revealInFinder(String absolutePath) async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('open', ['-R', absolutePath]);
    } catch (_) {}
  }

  // -----------------------------
  // Storage 삭제 (lesson_attachments 버킷)
  // -----------------------------
  Future<void> delete(String urlOrPath) async {
    String? key;
    if (urlOrPath.startsWith('http')) {
      key = _extractStorageKeyFromUrl(urlOrPath);
    } else {
      key = urlOrPath;
      if (key.startsWith('$_bucketName/')) {
        key = key.substring(_bucketName.length + 1);
      }
    }
    if (key == null || key.isEmpty) return;
    await _retry(() => _sb.storage.from(_bucketName).remove([key!]));
  }

  // ========= Save to Workspace then open =========

  bool _isAudioName(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.mp3') ||
        n.endsWith('.m4a') ||
        n.endsWith('.wav') ||
        n.endsWith('.aif') ||
        n.endsWith('.aiff') ||
        n.endsWith('.mp4') ||
        n.endsWith('.mov');
  }

  /// WORKSPACE에 저장 후 기본앱으로 연다.
  /// - filename: 화면/로컬 표시명(확장자 유지)
  /// - bucket/storagePath 제공 시, 로컬 저장 파일명을 bucket+storagePath로 고유화
  // REPLACE THIS FUNCTION
  Future<String> saveUrlToWorkspaceAndOpen({
    required String studentId,
    required String filename,
    required String url,
    String? bucket,
    String? storagePath,
  }) async {
    // 로컬 파일명 생성(버킷+스토리지 경로로 고유화)
    String safeLocalName({
      required String displayName,
      String? bkt,
      String? key,
    }) {
      final ext = p.extension(displayName);
      final base = p.basenameWithoutExtension(displayName);
      if ((bkt ?? '').isEmpty || (key ?? '').isEmpty) {
        return '${base.isEmpty ? "file" : base}$ext';
      }
      String norm(String s) => s
          .replaceAll(RegExp(r'^/+|/+$'), '')
          .replaceAll('/', '_')
          .replaceAll(r'\', '_');
      final stem = '${norm(bkt!)}__${norm(key!)}';
      final trimmed = (stem.length > 120)
          ? stem.substring(stem.length - 120)
          : stem;
      return '$trimmed$ext';
    }

    final localName = safeLocalName(
      displayName: filename,
      bkt: bucket,
      key: storagePath,
    );

    final dir = await _studentWorkspaceDir(studentId);
    final dst = File(p.join(dir.path, localName));

    // 다운로드 & 저장 (내부 헬퍼 활용)
    final bytes = await _downloadUrlToBytes(url);
    await dst.writeAsBytes(bytes, flush: true);

    final r = await OpenFilex.open(dst.path);
    if (r.type != ResultType.done) {
      throw StateError('기본 앱으로 열 수 없습니다: ${r.message}');
    }
    return dst.path; // ← 로컬 경로 반환
  }


  Future<String> saveBytesToWorkspaceAndOpen({
    required String studentId,
    required String filename,
    required Uint8List bytes,
  }) async {
    if (_isAudioName(filename)) {
      final tmp = await saveBytesFile(filename: filename, bytes: bytes);
      await openLocal(tmp.path);
      return tmp.path;
    }

    if (!_isDesktop) {
      final tmp = await saveBytesFile(filename: filename, bytes: bytes);
      await openLocal(tmp.path);
      return tmp.path;
    }

    final safeName = _displaySafeName(filename);
    final studentDir = await _studentWorkspaceDir(studentId);
    final sub = Directory(p.join(studentDir.path, 'Curriculum'));
    await _ensureDir(sub.path);

    final outPath = _avoidNameClash(sub.path, safeName);
    await File(outPath).writeAsBytes(bytes, flush: true);
    await openLocal(outPath);
    return outPath;
  }

  String _avoidNameClash(String dirPath, String fileName) {
    String candidate = p.join(dirPath, fileName);
    if (!File(candidate).existsSync()) return candidate;

    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    int i = 1;
    while (true) {
      final next = p.join(dirPath, '$base ($i)$ext');
      if (!File(next).existsSync()) return next;
      i++;
      if (i > 9999) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        return p.join(dirPath, '$base-$stamp$ext');
      }
    }
  }

  // [ADD] 리소스 한 건을 바로 기본앱으로 여는 헬퍼 (리소스 → signed URL → 워크스페이스 저장 → 기본앱 실행)
  // ↓↓↓ REPLACE: file_service.dart 의 openResourceWithDefaultApp 전체 교체
  Future<String> openResourceWithDefaultApp({
    required String studentId,
    required ResourceFile resource,
  }) async {
    final url = await ResourceService().signedUrl(resource);
    return await saveUrlToWorkspaceAndOpen(
      studentId: studentId,
      filename: resource.filename,
      url: url,
      bucket: resource.storageBucket, // ← 동일 파일명이라도 경로로 고유화
      storagePath: resource.storagePath,
    );
  }


  // [OPT] 시벨리우스 확장자를 “오디오/비디오”가 아닌 일반 문서로 취급 (기본앱으로 열리게 그대로 둠)
  // 현재 _isAudioName은 mp3/m4a/wav/aif/aiff/mp4/mov 만 true.
  // .sib는 여기에 안 걸리므로 이미 “기본앱” 경로가 맞음. (추가 수정 불필요)
}
