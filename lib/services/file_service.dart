// lib/services/file_service.dart
// 파일 첨부/열기 보조. 데스크탑 우선, 모바일/Web 제한 안내는 UI에서 처리.
class FileService {
  const FileService();

  Future<void> open(String pathOrUrl) async {
    // 실제 open_file / url_launcher 등은 pubspec 의존 필요하므로
    // 여기서는 UI에서 경고/안내만 처리하도록 남겨둔다.
    // macOS/Windows에서는 추후 open_file5 패키지로 연결하는 것을 권장.
  }
}
