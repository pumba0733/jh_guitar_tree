// v1.24.2 | 데스크탑 파일 첨부/업로드/열기/삭제 + 텍스트 저장
//
// 요구 의존성 (pubspec.yaml):
//   file_picker: ^8
//   open_filex: ^4
//   url_launcher: ^6
//   supabase_flutter: ^2
//   path_provider: ^2
//   path: ^1
//
// 표준 attachments 구조: `{path, url, name, size}`
// 보관 경로 규칙: lesson_attachments/{studentId}/{YYYY-MM-DD}/{filename}

import 'dart:convert';
import 'dart:io';

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

  // NOTE: 상수 테이블을 쓰고 싶으면 SupabaseBuckets.lessonAttachments 로 대체 가능
  static const String _bucketName = 'lesson_attachments';

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

  Future<Map<String, dynamic>> uploadPathToStorage({
    required String absolutePath,
    required String studentId,
    required String dateStr, // YYYY-MM-DD
  }) async {
    final file = File(absolutePath);
    if (!file.existsSync()) {
      throw ArgumentError('파일을 찾을 수 없습니다: $absolutePath');
    }
    final filename = p.basename(absolutePath);
    final storagePath = 'lesson_attachments/$studentId/$dateStr/$filename';
    final bytes = await file.readAsBytes();

    await _sb.storage
        .from(_bucketName)
        .uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );

    final publicUrl = _sb.storage.from(_bucketName).getPublicUrl(storagePath);
    return {
      'path': storagePath,
      'url': publicUrl,
      'name': filename,
      'size': bytes.length,
    };
  }

  Future<Map<String, dynamic>> uploadPickedFile({
    required PlatformFile picked,
    required String studentId,
    required String dateStr,
  }) async {
    if (picked.path != null) {
      return uploadPathToStorage(
        absolutePath: picked.path!,
        studentId: studentId,
        dateStr: dateStr,
      );
    }
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, picked.name);
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
  /// 여러 파일 선택 → Storage 업로드 → 첨부 리스트 반환
  Future<List<Map<String, dynamic>>> pickAndUploadMultiple({
    required String studentId,
    required String dateStr, // YYYY-MM-DD
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

  /// 문자열이 로컬 경로면 기본 앱으로, URL이면 외부 브라우저로 연다.
  Future<void> open(String pathOrUrl) async {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      await openUrl(pathOrUrl);
    } else {
      await openLocal(pathOrUrl);
    }
  }

  /// Storage에서 `url` 또는 `path`로 삭제 시도
  Future<void> delete(String urlOrPath) async {
    String? storagePath;
    if (urlOrPath.startsWith('http')) {
      // 공개 URL 형태: .../object/public/<bucket>/<path...>
      final idx = urlOrPath.indexOf('/object/public/');
      if (idx >= 0) {
        final sub = urlOrPath.substring(idx + '/object/public/'.length);
        // sub = '<bucket>/<key...>'
        final parts = sub.split('/');
        if (parts.isNotEmpty && parts.first == _bucketName) {
          storagePath = parts.skip(1).join('/');
        }
      }
    } else {
      // 이미 storage key라고 가정 (lesson_attachments/....)
      storagePath = urlOrPath;
      // 혹시 앞에 버킷명이 포함되어 있으면 제거
      if (storagePath.startsWith('$_bucketName/')) {
        storagePath = storagePath.substring(_bucketName.length + 1);
      }
    }

    if (storagePath == null || storagePath.isEmpty) return;
    await _sb.storage.from(_bucketName).remove([storagePath]);
  }

  // -----------------------------
  // 열기/URL
  // -----------------------------
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

  /// 첨부 객체(`{path,url,localPath,...}`) 우선순위 열기
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
}
