// lib/ui/components/file_clip.dart
// v1.28.3 | use_build_context_synchronously 경고 해소(메신저 인자 주입)
// - _open/_download/_reveal: BuildContext 대신 ScaffoldMessengerState 사용
// - showMenu 콜백 및 onPressed에서 messenger 사전 캡처 후 전달
// - 나머지 로직 동일

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../services/file_service.dart';

class FileClip extends StatelessWidget {
  final String name;
  final String? path;
  final String? url;
  final VoidCallback? onDelete;

  const FileClip({super.key, String? name, this.path, this.url, this.onDelete})
    : name = name ?? '첨부';

  IconData _iconFor(String filename) {
    final ext = p.extension(filename).toLowerCase();
    if (ext == '.pdf') {
      return Icons.picture_as_pdf;
    }
    if ([
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.heic',
    ].contains(ext)) {
      return Icons.image;
    }
    if (['.mp3', '.wav', '.m4a', '.flac', '.ogg', '.aiff'].contains(ext)) {
      return Icons.audiotrack;
    }
    if (['.mp4', '.mov', '.mkv', '.avi', '.webm'].contains(ext)) {
      return Icons.movie;
    }
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) {
      return Icons.archive;
    }
    if (['.doc', '.docx', '.rtf'].contains(ext)) {
      return Icons.description;
    }
    if (['.xls', '.xlsx', '.csv'].contains(ext)) {
      return Icons.table_chart;
    }
    if (['.ppt', '.pptx'].contains(ext)) {
      return Icons.slideshow;
    }
    if (['.txt', '.md', '.json', '.xml', '.yaml', '.yml'].contains(ext)) {
      return Icons.notes;
    }
    return Icons.insert_drive_file;
  }

  Map<String, dynamic> _toAttachmentMap() {
    return {
      'name': name,
      if (path != null) 'path': path,
      if (url != null) 'url': url,
    };
  }

  // ▼ BuildContext를 넘기지 않도록 시그니처 변경
  Future<void> _open(ScaffoldMessengerState messenger) async {
    try {
      await FileService().openAttachment(_toAttachmentMap());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('열기 실패: $e')));
    }
  }

  Future<void> _download(ScaffoldMessengerState messenger) async {
    try {
      final saved = await FileService().saveAttachmentToDownloads(
        _toAttachmentMap(),
      );
      messenger.showSnackBar(SnackBar(content: Text('다운로드 완료: $saved')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
    }
  }

  Future<void> _reveal(ScaffoldMessengerState messenger) async {
    try {
      // Finder 표시만 필요하므로 저장 경로 확보 → 표시
      final saved = await FileService().saveAttachmentToDownloads(
        _toAttachmentMap(),
      );
      await FileService().revealInFinder(saved);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('표시 실패: $e')));
    }
  }

  void _showMenu(BuildContext context, Offset pos) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // 사전 캡처
    final messenger = ScaffoldMessenger.of(context);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'open',
          child: ListTile(leading: Icon(Icons.open_in_new), title: Text('열기')),
        ),
        const PopupMenuItem(
          value: 'download',
          child: ListTile(leading: Icon(Icons.download), title: Text('다운로드')),
        ),
        const PopupMenuItem(
          value: 'reveal',
          child: ListTile(
            leading: Icon(Icons.folder_open),
            title: Text('Finder에서 보기'),
          ),
        ),
        if (onDelete != null)
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(leading: Icon(Icons.delete), title: Text('삭제')),
          ),
      ],
    ).then((v) async {
      // 여기서부터는 messenger만 사용 (context 비사용)
      switch (v) {
        case 'open':
          await _open(messenger);
          break;
        case 'download':
          await _download(messenger);
          break;
        case 'reveal':
          await _reveal(messenger);
          break;
        case 'delete':
          onDelete?.call();
          break;
        default:
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition), // 우클릭
      onLongPressStart: (d) => _showMenu(context, d.globalPosition), // 길게 누르기
      behavior: HitTestBehavior.opaque,
      child: InputChip(
        avatar: Icon(_iconFor(name)),
        label: Text(name),
        onPressed: () {
          // onPressed에서도 사전 캡처 후 전달
          final messenger = ScaffoldMessenger.of(context);
          _open(messenger);
        },
        onDeleted: onDelete,
        deleteIcon: onDelete == null ? null : const Icon(Icons.close),
      ),
    );
  }
}
