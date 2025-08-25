import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:cross_file/cross_file.dart';
import '../../services/file_service.dart';

class DropUploadArea extends StatefulWidget {
  final String studentId;
  final String dateStr; // YYYY-MM-DD
  final void Function(List<Map<String, dynamic>> uploaded) onUploaded;
  final void Function(Object error)? onError;

  const DropUploadArea({
    super.key,
    required this.studentId,
    required this.dateStr,
    required this.onUploaded,
    this.onError,
  });

  @override
  State<DropUploadArea> createState() => _DropUploadAreaState();
}

class _DropUploadAreaState extends State<DropUploadArea> {
  bool _hover = false;
  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) {
      return const SizedBox.shrink();
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (detail) async {
        try {
          final file = FileService.instance;
          final uploads = <Map<String, dynamic>>[];
          for (final f in detail.files) {
            // XFile 그대로 전달 → FileService.uploadXFile 내부에서
            // tempDir로 안전 복사 후 업로드 처리
            final u = await file.uploadXFile(
              xfile: XFile(f.path, name: f.name),
              studentId: widget.studentId,
              dateStr: widget.dateStr,
            );
            uploads.add(u);
          }
          widget.onUploaded(uploads);
        } catch (e) {
          widget.onError?.call(e);
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('드래그 업로드 실패: $e')));
          }
        } finally {
          if (mounted) setState(() => _hover = false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: _hover
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade400,
            width: 2,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(12),
          color: _hover
              ? Theme.of(context).colorScheme.primary.withOpacity(0.06)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.upload_file,
              color: _hover
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '여기에 파일을 드롭하여 업로드',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _hover
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
