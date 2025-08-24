// lib/ui/components/file_clip.dart
// v1.21 | 파일/URL 첨부 클립 (데스크탑 실행 우선, 시그니처: name(옵션), path(옵션), url(옵션))
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io' as io;

class FileClip extends StatelessWidget {
  final String name;
  final String? path; // 로컬/절대/상대 경로
  final String? url;  // http(s) 등 원격 링크
  final VoidCallback? onDelete;

  const FileClip({
    super.key,
    String? name,
    this.path,
    this.url,
    this.onDelete,
  }) : name = name ?? '첨부';

  Future<void> _open(BuildContext context) async {
    try {
      // 데스크탑 로컬 경로 우선
      if (!kIsWeb &&
          (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux)) {
        if (path != null && path!.isNotEmpty) {
          await OpenFilex.open(path!);
          return;
        }
      }
      // URL 열기 (OpenFilex가 URL도 기본 브라우저로 위임)
      if (url != null && url!.isNotEmpty) {
        await OpenFilex.open(url!);
        return;
      }

      // 열 수 없는 경우 안내
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('열 수 있는 경로/링크가 없습니다.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('열기 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Text(name),
      onPressed: () => _open(context),
      onDeleted: onDelete,
      deleteIcon: onDelete == null ? null : const Icon(Icons.close),
    );
  }
}
