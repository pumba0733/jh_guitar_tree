// lib/ui/components/file_clip.dart
// v1.29.0 | 첨부 열기 훅(onOpen) 추가 → XSC 플로우 주입 가능
// - onOpen(ScaffoldMessengerState, attachmentMap) 콜백 지원
// - 제공되면 FileService 대신 콜백 실행 (에러 스낵바는 그대로 처리)
// - 기존 동작(없을 때 FileService로 열기/다운로드/표시)은 유지

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../services/file_service.dart';

class FileClip extends StatelessWidget {
  final String name;
  final String? path;
  final String? url;
  final VoidCallback? onDelete;

  /// v1.29.0: 부모가 열기 동작을 커스터마이즈할 수 있도록 훅 제공
  /// (예: LessonLinksService.openFromAttachment → XSC 플로우로 라우팅)
  final Future<void> Function(
    ScaffoldMessengerState messenger,
    Map<String, dynamic> attachment,
  )?
  onOpen;

  const FileClip({
    super.key,
    String? name,
    this.path,
    this.url,
    this.onDelete,
    this.onOpen,
  }) : name = name ?? '첨부';

  IconData _iconFor(String filename) {
    final ext = p.extension(filename).toLowerCase();
    if (ext == '.pdf') return Icons.picture_as_pdf;
    if ([
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.heic',
    ].contains(ext)) {
      return Icons.image; // ← 블록으로 변경 (lint fix)
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
    if (['.doc', '.docx', '.rtf'].contains(ext)) return Icons.description;
    if (['.xls', '.xlsx', '.csv'].contains(ext)) return Icons.table_chart;
    if (['.ppt', '.pptx'].contains(ext)) return Icons.slideshow;
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

  Future<void> _open(ScaffoldMessengerState messenger) async {
    try {
      // v1.29.0: onOpen 훅이 있으면 우선 사용 (예: XSC 플로우 진입)
      if (onOpen != null) {
        await onOpen!(messenger, _toAttachmentMap());
        return;
      }
      // 기본: FileService로 열기
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
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      onLongPressStart: (d) => _showMenu(context, d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: InputChip(
        avatar: Icon(_iconFor(name)),
        label: Text(name),
        onPressed: () {
          final messenger = ScaffoldMessenger.of(context);
          _open(messenger);
        },
        onDeleted: onDelete,
        deleteIcon: onDelete == null ? null : const Icon(Icons.close),
      ),
    );
  }
}
