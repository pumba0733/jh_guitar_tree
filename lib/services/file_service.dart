// lib/services/file_service.dart
// v1.26.3 | 첨부 업로드/열기/삭제 + 텍스트 저장 + XFile 지원
//        | ⚙️ Storage object key ASCII-safe 처리(InvalidKey 해결)
//        | 기본앱으로 열기(로컬 temp 캐시) + Downloads 저장 + Finder 표시
//
// 의존성: file_picker ^8 / open_filex ^4 / url_launcher ^6 / supabase_flutter ^2
//        path_provider ^2 / path ^1 / cross_file ^0.3
//
// attachments 구조: { path, url, name, size, localPath? }
//   - name: 화면 표시는 원본명(한글/공백 포함 OK)
//   - path: Storage object key (ASCII-safe)
//   - localPath: temp 캐시(저장 시 DB에 넣지 말 것)

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, consolidateHttpClientResponseBytes;
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
  // 화면 표시용 파일명(유니코드 보존, 경로/제어문자만 치환)
  // -----------------------------
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

  // -----------------------------
  // Storage object key용 파일명(ASCII만 허용: A-Z a-z 0-9 . _ -)
  //  - 공백/한글/특수문자 전부 '_'로 치환 → InvalidKey 방지
  // -----------------------------
  String _keySafeName(String raw) {
    final ext = p.extension(raw);
    var base = p.basenameWithoutExtension(raw);
    // 제어/경로문자 제거
    base = base.replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_');
    // ASCII whitelist
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // 연속 '_' 압축
    base = base.replaceAll(RegExp(r'_+'), '_').trim();
    if (base.isEmpty) {
      base = DateTime.now().millisecondsSinceEpoch.toString();
    }
    // 확장자도 안전화
    var safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (safeExt.length > 10) safeExt = safeExt.substring(0, 10);
    return '$base$safeExt';
  }

  // -----------------------------
  // 기본 폴더(resolve)
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
      withReadStream: true,
      withData: true,
      dialogTitle: '첨부할 파일을 선택하세요',
    );
    if (result == null) return const [];
    return result.files;
  }

  // 드래그(XFile) 업로드: temp 복사 후 업로드
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

  // 파일 경로 업로드
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
    final keyName = _keySafeName(displayName); // ✅ Storage용 ASCII
    final objectKey = '$studentId/$dateStr/$keyName';
    final bytes = await file.readAsBytes();

    await _sb.storage
        .from(_bucketName)
        .uploadBinary(
          objectKey,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );

    final publicUrl = _sb.storage.from(_bucketName).getPublicUrl(objectKey);
    return {
      'path': objectKey, // ASCII-safe 키
      'url': publicUrl,
      'name': displayName, // 화면 표시는 원본명
      'size': bytes.length,
    };
  }

  // FilePicker(PlatformFile) 업로드
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

  // 화면 호환 래퍼
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
  // 열기 / URL
  // -----------------------------
  Future<void> open(String pathOrUrl) async {
    if (pathOrUrl.startsWith('http')) {
      await openUrl(pathOrUrl);
    } else {
      await openLocal(pathOrUrl);
    }
  }

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

  // -----------------------------
  // 로컬 캐시 확보(없으면 다운로드)
  // -----------------------------
  String? _extractStorageKeyFromUrl(String url) {
    final idx = url.indexOf('/object/public/');
    if (idx < 0) return null;
    final sub = url.substring(idx + '/object/public/'.length);
    final parts = sub.split('/');
    if (parts.isEmpty) return null;
    if (parts.first == _bucketName) {
      return parts.skip(1).join('/');
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
        bytes = await _sb.storage.from(_bucketName).download(key);
        fallbackName = p.basename(key);
      } else {
        final client = HttpClient();
        final res = await (await client.getUrl(Uri.parse(url))).close();
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
      bytes = await _sb.storage.from(_bucketName).download(path);
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
  // 다운로드(영구 저장): Downloads 폴더에 저장 + Finder에서 보기
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
    await _sb.storage.from(_bucketName).remove([key]);
  }
}
