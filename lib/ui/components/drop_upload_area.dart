// lib/ui/components/drop_upload_area.dart
// v1.28.4 | control_flow_in_finally 경고 해소
// - finally 블록에서 return 제거 → if (mounted) setState(...)만 수행

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
  bool _uploading = false;
  int _done = 0;
  int _total = 0;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> _handleDropFiles(List<XFile> files) async {
    if (_uploading) return;

    setState(() {
      _uploading = true;
      _done = 0;
      _total = files.length;
    });

    try {
      final fs = FileService.instance;
      final uploads = <Map<String, dynamic>>[];

      // 동시 업로드 제한: 3개씩 배치 처리
      const concurrent = 3;
      for (var i = 0; i < files.length; i += concurrent) {
        final batch = files.sublist(
          i,
          (i + concurrent > files.length) ? files.length : i + concurrent,
        );

        final results = await Future.wait(
          batch.map((xf) async {
            final u = await fs.uploadXFile(
              xfile: XFile(xf.path, name: xf.name),
              studentId: widget.studentId,
              dateStr: widget.dateStr,
            );
            if (!mounted) return u;
            setState(() => _done += 1);
            return u;
          }),
        );

        uploads.addAll(results);
      }

      widget.onUploaded(uploads);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${uploads.length}개 파일 업로드 완료'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      widget.onError?.call(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('드래그 업로드 실패: $e')));
    } finally {
      // ❌ return 금지 → ✅ mounted일 때만 상태 정리
      if (mounted) {
        setState(() {
          _hover = false;
          _uploading = false;
          _done = 0;
          _total = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return const SizedBox.shrink();

    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (detail) async {
        if (_uploading) return;
        await _handleDropFiles(detail.files);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: _hover
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade400,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
          color: _hover
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.06)
              : null,
        ),
        child: _uploading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('업로드 중… $_done/$_total'),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.upload_file,
                    color: _hover
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '여기에 파일을 드롭하여 업로드',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _hover
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
