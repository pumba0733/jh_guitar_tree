// lib/screens/settings/export_screen.dart
// v1.21: 백업 JSON 파일 저장 + 클립보드 복사
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../../services/backup_service.dart';
import '../../services/file_service.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});
  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final _backup = BackupService();
  String? _studentId;
  String? _json;
  String? _savedPath;
  bool _loading = false;
  final _idController = TextEditingController();

  Future<void> _buildJson() async {
    setState(() {
      _loading = true;
      _json = null;
      _savedPath = null;
    });
    try {
      final sid = _idController.text.trim();
      final data = await _backup.buildStudentBackupJson(sid);
      if (!mounted) return;
      setState(() {
        _studentId = sid;
        _json = const JsonEncoder.withIndent('  ').convert(data);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오류: $e')));
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    if (_json == null) return;
    await Clipboard.setData(ClipboardData(text: _json!));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('클립보드로 복사되었습니다.')));
    }
  }

  Future<void> _saveFile() async {
    if (_json == null) return;
    final filename =
        'backup_${DateTime.now().toIso8601String().split("T").first}_$_studentId.json';
    final f = await FileService.saveTextFile(
      filename: filename,
      content: _json!,
    );
    if (!mounted) return;
    setState(() {
      _savedPath = f.path;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('저장됨: ${f.path}')));
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('백업 (JSON Export)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _idController,
                    decoration: const InputDecoration(labelText: '학생 ID 입력'),
                    onChanged: (v) => _studentId = v,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _buildJson,
                  icon: const Icon(Icons.build),
                  label: const Text('백업 생성'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_json != null) ...[
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_all),
                    label: const Text('클립보드 복사'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saveFile,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('파일로 저장'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_savedPath != null)
                Text('저장 경로: $_savedPath', style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Expanded(
                child: SelectableText(
                  _json!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
