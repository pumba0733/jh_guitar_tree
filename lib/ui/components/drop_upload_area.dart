// lib/ui/components/drop_upload_area.dart
// v1.67 | 드래그&드롭 → 리소스 업로드 + 오늘레슨 링크로 전환
// - onUploaded: List<ResourceFile> 반환
// - 내부에서 FileService.attachXFilesAsResourcesForTodayLesson 사용

import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:cross_file/cross_file.dart';
import '../../services/file_service.dart';
import '../../models/resource.dart';

class DropUploadArea extends StatefulWidget {
  final String studentId;
  final String dateStr; // YYYY-MM-DD (표시용, 실제 업로드는 리소스 버킷)
  final void Function(List<ResourceFile> uploaded) onUploaded;
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
    if (_uploading || files.isEmpty) return;

    setState(() {
      _uploading = true;
      _done = 0;
      _total = files.length;
    });

    try {
      final fs = FileService.instance;

      // 배치 업로드(최대 동시 3권장) – attachXFilesAsResourcesForTodayLesson는 순차처리
      // 필요 시 여기서 files를 청크로 나눠 진행율 표기 세분화 가능
      final uploaded = await fs.attachXFilesAsResourcesForTodayLesson(
        studentId: widget.studentId,
        xfiles: files,
        nodeId: null,
      );

      widget.onUploaded(uploaded);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('리소스 ${uploaded.length}개 업로드 및 링크 완료'),
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
                    '여기에 파일을 드롭하여 오늘 레슨에 추가',
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
