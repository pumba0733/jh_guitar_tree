// lib/screens/summary/lesson_summary_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../services/summary_service.dart';
import '../../models/lesson.dart';
import '../../routes/app_routes.dart';

class LessonSummaryScreen extends StatefulWidget {
  const LessonSummaryScreen({super.key});

  @override
  State<LessonSummaryScreen> createState() => _LessonSummaryScreenState();
}

class _LessonSummaryScreenState extends State<LessonSummaryScreen> {
  final _lessonSvc = LessonService();
  final _summarySvc = SummaryService();

  List<Lesson> _items = const [];
  final _selected = <String>{};
  DateTime? _from;
  DateTime? _to;
  String? _query;
  bool _loading = false;

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final init = isFrom ? (_from ?? now) : (_to ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) _from = picked;
        else _to = picked;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final stu = AuthService().currentStudent;
    if (stu == null) {
      setState(() {
        _items = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await _lessonSvc.listStudentFiltered(
        studentId: stu.id,
        from: _from,
        to: _to,
        query: _query,
      );
      setState(() => _items = data);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _createSummary() async {
    final stu = AuthService().currentStudent;
    if (stu == null || _selected.isEmpty) return;
    final id = await _summarySvc.createSummaryForSelectedLessons(
      studentId: stu.id,
      type: '기간별',
      periodStart: _from,
      periodEnd: _to,
      selectedLessonIds: _selected.toList(),
    );
    if (!mounted) return;
    Navigator.pushNamed(context, AppRoutes.summaryResult, arguments: id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('수업 요약')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: '검색(주제/메모/다음 계획)'),
                    onChanged: (v) {
                      _query = v.trim().isEmpty ? null : v.trim();
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _pickDate(isFrom: true),
                  child: Text(_from == null ? '시작일' : _from!.toIso8601String().split('T').first),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _pickDate(isFrom: false),
                  child: Text(_to == null ? '종료일' : _to!.toIso8601String().split('T').first),
                ),
              ],
            ),
          ),
          const Divider(height: 0),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 0),
                    itemBuilder: (_, i) {
                      final l = _items[i];
                      final date = l.date.toIso8601String().split('T').first;
                      final checked = _selected.contains(l.id);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) _selected.add(l.id);
                            else _selected.remove(l.id);
                          });
                        },
                        title: Text(l.subject ?? '(제목 없음)'),
                        subtitle: Text('날짜: $date  유튜브: ${l.youtubeUrl ?? "-"}'),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: ElevatedButton.icon(
                onPressed: _selected.isEmpty ? null : _createSummary,
                icon: const Icon(Icons.auto_fix_high),
                label: Text('요약 생성 (${_selected.length}개 선택됨)'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
