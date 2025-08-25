// lib/services/file_service.dart
// v1.24.4 | 데스크탑 파일 첨부/업로드/열기/삭제 + 텍스트 저장 + XFile 지원 + 파일명 정규화
//        | ✅ macOS 권한 이슈 해결: 언제나 tempDir로 복사 후 업로드
//
// 요구 의존성 (pubspec.yaml):
//   file_picker: ^8
//   open_filex: ^4
//   url_launcher: ^6
//   supabase_flutter: ^2
//   path_provider: ^2
//   path: ^1
//   cross_file: ^0.3
//
// 표준 attachments 구조: `{path, url, name, size}`
// 보관 경로 규칙: {studentId}/{YYYY-MM-DD}/{filename}

import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

  // -----------------------------
  // 파일명 정규화 (공백/한글/특수문자 → _ 치환, 확장자 유지)
  // -----------------------------
  String _sanitizeFileName(String raw) {
    final ext = p.extension(raw);
    final base = p.basenameWithoutExtension(raw);
    final safeBase = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final finalBase = safeBase.isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : safeBase;
    return '$finalBase$ext';
  }

  // -----------------------------
  // 기본 다운로드/문서 폴더
  // -----------------------------
  static Future<Directory> _resolveDownloadDir() async {
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
    final dir = await _resolveDownloadDir();
    final file = File(p.join(dir.path, filename));
    return file.writeAsString(content);
  }

  // -----------------------------
  // 로컬 선택 + 업로드
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
      withData: false,
      withReadStream: true,
    );
    if (result == null) return const [];
    return result.files;
  }

  // ✅ Finder 드래그(XFile) → 언제나 tempDir로 안전 복사 후 업로드
  Future<Map<String, dynamic>> uploadXFile({
    required XFile xfile,
    required String studentId,
    required String dateStr,
  }) async {
    final safeName = _sanitizeFileName(xfile.name);
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, safeName);

    if (xfile.path.isNotEmpty) {
      // 원본 경로는 읽기만 가능한 경우가 많음 → tempDir로 복사
      final src = File(xfile.path);
      await src.copy(tempPath);
      return uploadPathToStorage(
        absolutePath: tempPath,
        studentId: studentId,
        dateStr: dateStr,
      );
    }

    final bytes = await xfile.readAsBytes();
    final f = await File(tempPath).writeAsBytes(bytes);
    return uploadPathToStorage(
      absolutePath: f.path,
      studentId: studentId,
      dateStr: dateStr,
    );
  }

  Future<Map<String, dynamic>> uploadPathToStorage({
    required String absolutePath,
    required String studentId,
    required String dateStr, // YYYY-MM-DD
  }) async {
    final file = File(absolutePath);
    if (!file.existsSync()) {
      throw ArgumentError('파일을 찾을 수 없습니다: $absolutePath');
    }

    final filename = _sanitizeFileName(p.basename(absolutePath));
    final storageKey = '$studentId/$dateStr/$filename';
    final bytes = await file.readAsBytes();

    await _sb.storage
        .from(_bucketName)
        .uploadBinary(
          storageKey,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );

    final publicUrl = _sb.storage.from(_bucketName).getPublicUrl(storageKey);
    return {
      'path': storageKey,
      'url': publicUrl,
      'name': filename,
      'size': bytes.length,
    };
  }

  // ✅ FilePicker(PlatformFile) → path가 있어도 tempDir로 복사 후 업로드
  Future<Map<String, dynamic>> uploadPickedFile({
    required PlatformFile picked,
    required String studentId,
    required String dateStr,
  }) async {
    final safeName = _sanitizeFileName(picked.name);
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, safeName);

    if (picked.path != null) {
      final src = File(picked.path!);
      await src.copy(tempPath);
      return uploadPathToStorage(
        absolutePath: tempPath,
        studentId: studentId,
        dateStr: dateStr,
      );
    }

    final out = File(tempPath).openWrite();
    if (picked.readStream != null) {
      await picked.readStream!.pipe(out);
    } else if (picked.bytes != null) {
      out.add(picked.bytes!);
      await out.flush();
      await out.close();
    } else {
      await out.close();
      throw StateError('파일 데이터를 읽을 수 없습니다: ${picked.name}');
    }
    return uploadPathToStorage(
      absolutePath: tempPath,
      studentId: studentId,
      dateStr: dateStr,
    );
  }

  // -----------------------------
  // 화면에서 기대하는 래퍼 (호환용)
  // -----------------------------
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
  // 열기/URL
  // -----------------------------
  Future<void> open(String pathOrUrl) async {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      await openUrl(pathOrUrl);
    } else {
      await openLocal(pathOrUrl);
    }
  }

  Future<void> openLocal(String absolutePath) async {
    if (!_isDesktop) {
      throw UnsupportedError('이 기능은 데스크탑에서만 지원됩니다.');
    }
    await OpenFilex.open(absolutePath);
  }

  Future<void> openUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) throw StateError('URL을 열 수 없습니다: $url');
  }

  Future<void> openAttachment(Map<String, dynamic> att) async {
    final local = (att['localPath'] ?? '').toString();
    final url = (att['url'] ?? '').toString();
    if (local.isNotEmpty && File(local).existsSync()) {
      await openLocal(local);
      return;
    }
    if (url.isNotEmpty) {
      await openUrl(url);
      return;
    }
    throw ArgumentError('열 수 있는 경로/URL이 없습니다.');
  }

  // -----------------------------
  // Storage 삭제
  // -----------------------------
  Future<void> delete(String urlOrPath) async {
    String? storageKey;
    if (urlOrPath.startsWith('http')) {
      final idx = urlOrPath.indexOf('/object/public/');
      if (idx >= 0) {
        final sub = urlOrPath.substring(idx + '/object/public/'.length);
        final parts = sub.split('/');
        if (parts.isNotEmpty && parts.first == _bucketName) {
          storageKey = parts.skip(1).join('/');
        }
      }
    } else {
      storageKey = urlOrPath;
      if (storageKey.startsWith('$_bucketName/')) {
        storageKey = storageKey.substring(_bucketName.length + 1);
      }
    }
    if (storageKey == null || storageKey.isEmpty) return;
    await _sb.storage.from(_bucketName).remove([storageKey]);
  }
}
