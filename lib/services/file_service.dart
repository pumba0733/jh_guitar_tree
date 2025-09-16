// lib/services/file_service.dart
// v1.28.4 | 네트워크 안정화(P2) + URL 키추출 보강(public/sign/auth) + contentType 전달
// - 재시도/타임아웃 유지
// - _extractStorageKeyFromUrl: /object/public/, /object/sign/, /object/auth/ 지원
// - uploadBinary 시 FileOptions.contentType 전달(가능할 때)
// - 스마트오픈/다운로드 흐름 기존과 동일

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

class FileService {
  FileService._();
  static final FileService instance = FileService._();
  factory FileService() => instance;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  SupabaseClient get _sb => Supabase.instance.client;

  static const String _bucketName = 'lesson_attachments';

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
  // Downloads 폴더/대체 폴더
  // -----------------------------
  static Future<Directory> _resolveDownloadsDir() async {
    try {
      if (_isDesktop) {
        final d = await getDownloadsDirectory();
        if (d != null) return d;
      }
    } catch (_) {}
    return getApplicationDocumentsDirectory();
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
  // 로컬 선택/업로드
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
  // 열기(기본앱 고정)
  // -----------------------------
  Future<void> openLocal(String absolutePath) async {
    if (!_isDesktop) throw UnsupportedError('이 기능은 데스크탑에서만 지원됩니다.');
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

  /// URL이라도 "항상 기본 앱"으로 열기 위한 스마트 오픈
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

  // public/signed/auth URL 모두에서 스토리지 키 추출 시도
  String? _extractStorageKeyFromUrl(String url) {
    // 형태 예시:
    // /storage/v1/object/public/<bucket>/<key...>
    // /storage/v1/object/sign/<bucket>/<key...>?token=...
    // /storage/v1/object/auth/<bucket>/<key...>
    final patterns = <String>[
      '/object/public/',
      '/object/sign/',
      '/object/auth/',
    ];
    for (final prefix in patterns) {
      final idx = url.indexOf(prefix);
      if (idx >= 0) {
        final sub = url.substring(idx + prefix.length);
        final parts = sub.split('?').first.split('/');
        if (parts.isEmpty) return null;
        if (parts.first == _bucketName) {
          return parts.skip(1).join('/');
        }
      }
    }
    return null;
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
    final outPath = p.join(dir.path, outName);
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
  // Storage 삭제
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
}
