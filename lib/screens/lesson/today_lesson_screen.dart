// lib/screens/lesson/today_lesson_screen.dart
// v1.21.2 | 오늘 수업 화면 (arguments 기반 studentId 전달)
import 'package:flutter/material.dart';
import '../../services/lesson_service.dart';
import '../../services/auth_service.dart';
import '../../ui/components/save_status_indicator.dart';

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _nextCtl = TextEditingController();

  bool _saving = false;
  String? _lessonId;
  late String _studentId;
  String? _teacherId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _studentId =
        (args?['studentId'] as String?) ??
        AuthService().currentStudent?.id ??
        '';
    _teacherId = args?['teacherId'] as String?;

    if (_studentId.isEmpty) {
      throw Exception('TodayLessonScreen requires studentId');
    }

    _ensureTodayRow();
  }

  Future<void> _ensureTodayRow() async {
    final today = DateTime.now();
    final d0 = DateTime(today.year, today.month, today.day);
    final dateStr = d0.toIso8601String().split('T').first;

    final list = await _service.listByStudent(
      _studentId,
      from: d0,
      to: d0,
      limit: 1,
    );

    Map<String, dynamic> row;
    if (list.isNotEmpty) {
      row = list.first;
    } else {
      row = await _service.upsert({
        'student_id': _studentId,
        if (_teacherId != null) 'teacher_id': _teacherId,
        'date': dateStr,
        'subject': '',
        'memo': '',
        'next_plan': '',
      });
    }

    _lessonId = row['id']?.toString();
    _subjectCtl.text = (row['subject'] ?? '').toString();
    _memoCtl.text = (row['memo'] ?? '').toString();
    _nextCtl.text = (row['next_plan'] ?? '').toString();

    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (_lessonId == null) return;
    setState(() => _saving = true);
    try {
      await _service.upsert({
        'id': _lessonId,
        'student_id': _studentId,
        if (_teacherId != null) 'teacher_id': _teacherId,
        'subject': _subjectCtl.text,
        'memo': _memoCtl.text,
        'next_plan': _nextCtl.text,
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SaveStatus status = _saving ? SaveStatus.saving : SaveStatus.idle;

    return Scaffold(
      appBar: AppBar(title: const Text('오늘 수업')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _subjectCtl,
              decoration: const InputDecoration(labelText: '주제'),
              onChanged: (_) => _save(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _memoCtl,
              decoration: const InputDecoration(labelText: '메모'),
              maxLines: 4,
              onChanged: (_) => _save(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nextCtl,
              decoration: const InputDecoration(labelText: '다음 계획'),
              onChanged: (_) => _save(),
            ),
            const SizedBox(height: 12),
            SaveStatusIndicator(status: status),
          ],
        ),
      ),
    );
  }
}
