// lib/ui/components/file_clip.dart
import 'package:flutter/material.dart';

class FileClip extends StatelessWidget {
  final String name;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;
  const FileClip({super.key, required this.name, this.onOpen, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(name, overflow: TextOverflow.ellipsis),
      onDeleted: onDelete,
      deleteIcon: const Icon(Icons.close, size: 16),
    );
  }
}
