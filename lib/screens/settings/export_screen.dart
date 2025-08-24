// lib/screens/settings/export_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final _backup = BackupService();
  String? _json;
  bool _loading = false;

  Future<void> _doExport() async {
    final stu = AuthService().currentStudent;
    if (stu == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('학생 로그인 상태에서 사용하세요.')));
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await _backup.buildStudentBackupJson(stu.id);
      setState(() => _json = const JsonEncoder.withIndent('  ').convert(data));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('백업')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _loading ? null : _doExport,
              icon: const Icon(Icons.download),
              label: const Text('현재 학생 데이터 JSON 생성'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _json == null
                  ? const Center(child: Text('JSON 미생성'))
                  : SelectableText(_json!),
            ),
          ],
        ),
      ),
    );
  }
}
