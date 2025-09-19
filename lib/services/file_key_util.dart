// v1.61 | Storage Key ASCII-safe 유틸 + 표준 경로
class FileKeyUtil {
  // 영문/숫자/._- 만 허용, 나머지는 '_'
  static String keySafe(String input) {
    final buf = StringBuffer();
    for (final ch in input.runes) {
      final c = String.fromCharCode(ch);
      final ok = RegExp(r'[A-Za-z0-9._-]').hasMatch(c);
      buf.write(ok ? c : '_');
    }
    var s = buf.toString();
    s = s.replaceAll(RegExp(r'_+'), '_');
    s = s.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
    return s.isEmpty ? '_' : s;
  }

  /// 표준 첨부 경로: lesson/{lessonId}/{uuid}.ext  (ext는 ".xsc" 형태)
  static String lessonAttachmentKey({
    required String lessonId,
    required String uuid,
    required String ext, // ".xsc" 같은 형태(점 포함/미포함 허용)
  }) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    return 'lesson/$lessonId/$uuid${e.toLowerCase()}';
  }
}
