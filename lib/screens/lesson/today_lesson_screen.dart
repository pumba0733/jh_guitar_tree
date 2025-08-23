// lib/screens/lesson/today_lesson_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../ui/components/save_status_indicator.dart';

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});
  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final _subject = TextEditingController();
  final _memo = TextEditingController();
  final _next = TextEditingController();
  final _youtube = TextEditingController();

  final _lessonSvc = LessonService();
  SaveState _state = SaveState.idle;
  DateTime? _savedAt;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 초기값 로드: 오늘 레슨을 upsert해서 폼을 채움(없으면 생성)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final stu = AuthService().currentStudent.value;
      if (stu == null) return;
      final lesson = await _lessonSvc.upsertToday(studentId: stu.id);
      setState(() {
        _subject.text = lesson.subject ?? '';
        _memo.text = lesson.memo ?? '';
        _next.text = lesson.nextPlan ?? '';
        _youtube.text = lesson.youtubeUrl ?? '';
      });
    });

    for (final c in [_subject, _memo, _next, _youtube]) {
      c.addListener(_onChanged);
    }
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _saveNow);
    setState(() => _state = SaveState.saving);
  }

  Future<void> _saveNow() async {
    final stu = AuthService().currentStudent.value;
    if (stu == null) return;
    try {
      await _lessonSvc.patchToday(stu.id, {
        'subject': _subject.text.trim().isEmpty ? null : _subject.text.trim(),
        'memo': _memo.text.trim().isEmpty ? null : _memo.text.trim(),
        'next_plan': _next.text.trim().isEmpty ? null : _next.text.trim(),
        'youtube_url': _youtube.text.trim().isEmpty
            ? null
            : _youtube.text.trim(),
      });
      setState(() {
        _state = SaveState.saved;
        _savedAt = DateTime.now();
      });
    } catch (e) {
      setState(() => _state = SaveState.error);
    }
  }

  @override
  void dispose() {
    for (final c in [_subject, _memo, _next, _youtube]) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stu = AuthService().currentStudent.value;
    if (stu == null) {
      return const Scaffold(body: Center(child: Text('학생 로그인 후 이용해주세요')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('오늘 수업'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: SaveStatusIndicator(state: _state, savedAt: _savedAt),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text(
              '학생: ${stu.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subject,
              decoration: const InputDecoration(
                labelText: '주제',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _memo,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '수업 메모',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _next,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '다음 계획',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _youtube,
              decoration: const InputDecoration(
                labelText: '유튜브 링크(선택)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '입력하면 자동 저장돼요. 우측 상단 상태를 확인하세요.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
