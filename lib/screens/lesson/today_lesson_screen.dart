// lib/screens/lesson/today_lesson_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../services/retry_queue_service.dart';
import '../../services/log_service.dart';
import '../../ui/components/save_status_indicator.dart';

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});
  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final _lessonSvc = LessonService();
  final _retry = RetryQueueService();

  final _subject = TextEditingController();
  final _memo = TextEditingController();
  final _next = TextEditingController();
  final _youtube = TextEditingController();

  SaveState _state = SaveState.idle;
  DateTime? _savedAt;
  Timer? _debounce;

  void _queueSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final stu = AuthService().currentStudent;
      if (stu == null) return;
      final patch = {
        'subject': _subject.text,
        'memo': _memo.text,
        'next_plan': _next.text,
        'youtube_url': _youtube.text,
      };
      setState(() {
        _state = SaveState.saving;
      });
      try {
        await _lessonSvc.patchToday(
          studentId: stu.id,
          subject: _subject.text,
          memo: _memo.text,
          nextPlan: _next.text,
          youtubeUrl: _youtube.text,
        );
        setState(() {
          _state = SaveState.saved;
          _savedAt = DateTime.now();
        });
        await LogService.insertLog(type: 'lesson_save', payload: {'student_id': stu.id});
      } catch (e) {
        // 실패 시 큐에 넣고 표시
        _retry.enqueueTodayPatch(stu.id, patch);
        setState(() => _state = SaveState.error);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final stu = AuthService().currentStudent;
      if (stu == null) return;
      try {
        final lesson = await _lessonSvc.upsertToday(studentId: stu.id);
        setState(() {
          _subject.text = lesson.subject ?? '';
          _memo.text = lesson.memo ?? '';
          _next.text = lesson.nextPlan ?? '';
          _youtube.text = lesson.youtubeUrl ?? '';
        });
      } catch (_) {/* ignore */}
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subject.dispose();
    _memo.dispose();
    _next.dispose();
    _youtube.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('오늘 수업'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SaveStatusIndicator(state: _state, savedAt: _savedAt)),
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _subject,
            decoration: const InputDecoration(labelText: '주제'),
            onChanged: (_) => _queueSave(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _memo,
            decoration: const InputDecoration(labelText: '메모'),
            maxLines: 5,
            onChanged: (_) => _queueSave(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _next,
            decoration: const InputDecoration(labelText: '다음 계획'),
            maxLines: 3,
            onChanged: (_) => _queueSave(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _youtube,
            decoration: const InputDecoration(labelText: '유튜브 링크'),
            keyboardType: TextInputType.url,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            onChanged: (_) => _queueSave(),
          ),
          const SizedBox(height: 20),
          Text('실패 큐: ${_retry.pendingCount}건', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 4),
          ElevatedButton.icon(
            onPressed: () async {
              final (ok, fail) = await _retry.flushAll(lessonService: _lessonSvc);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('재시도 완료: 성공 $ok, 실패 $fail')),
              );
            },
            icon: const Icon(Icons.refresh),
            label: const Text('저장 재시도'),
          ),
        ],
      ),
    );
  }
}
