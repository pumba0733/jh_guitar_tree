// lib/services/file_service.dart
// v1.21 데스크탑 파일 저장/열기 유틸
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileService {
  /// Downloads/문서 폴더 중 가능한 경로 반환
  static Future<Directory> _resolveDownloadDir() async {
    try {
      final d = await getDownloadsDirectory(); // macOS/Windows
      if (d != null) return d;
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return docs;
  }

  static Future<File> saveTextFile({
    required String filename,
    required String content,
  }) async {
    final dir = await _resolveDownloadDir();
    final file = File('${dir.path}/$filename');
    return file.writeAsString(content);
  }
}
