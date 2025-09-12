// lib/screens/settings/import_screen.dart
// v1.21.1 | control_flow_in_finally 경고 해소
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/backup_service.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _controller = TextEditingController();
  final _backup = BackupService();
  bool _loading = false;
  String? _result;
  String? _error;

  Future<void> _doImport() async {
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final data = _backup.parseBackupJson(_controller.text);
      final (nLessons, nSummaries) = await _backup.restoreFromJson(data);
      if (!mounted) return;
      setState(() => _result = '복원 완료: 레슨 $nLessons건, 요약 $nSummaries건');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      // ⚠️ return 금지 → 조건부 setState만 수행
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  // 샘플 JSON 예시를 에디터에 채워넣기
  void _fillSample() {
    const sample = {
      "version": "v1.21",
      "student_id": "PUT_STUDENT_ID",
      "lessons": [
        {
          "id": null,
          "student_id": "PUT_STUDENT_ID",
          "teacher_id": null,
          "date": "2025-08-20",
          "subject": "코드 진행 연습",
          "keywords": ["리듬", "코드체인지"],
          "memo": "Am-Dm-G-C 순환, 80bpm",
          "next_plan": "다음시간 90bpm",
          "attachments": [],
          "youtube_url": "",
        },
      ],
      "summaries": [
        {
          "id": null,
          "student_id": "PUT_STUDENT_ID",
          "teacher_id": null,
          "type": "기간별",
          "period_start": "2025-08-01",
          "period_end": "2025-08-31",
          "keywords": ["리듬", "코드체인지"],
          "selected_lesson_ids": [],
          "result_student": "샘플 요약(학생용)",
          "result_parent": "샘플 요약(보호자용)",
          "result_blog": "샘플 요약(블로그용)",
          "result_teacher": "샘플 요약(강사용)",
          "visible_to": ["teacher", "admin"],
        },
      ],
    };
    _controller.text = const JsonEncoder.withIndent('  ').convert(sample);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('복원 (JSON Import)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _fillSample,
                  icon: const Icon(Icons.dataset),
                  label: const Text('샘플 채우기'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _doImport,
                  icon: const Icon(Icons.upload),
                  label: const Text('복원 실행'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  hintText: '여기에 백업 JSON을 붙여넣으세요',
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            if (_result != null)
              Text(
                _result!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
