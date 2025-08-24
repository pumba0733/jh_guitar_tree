// lib/screens/lesson/lesson_history_screen.dart
// v1.21.2 | 학생별 지난 수업 복습 화면 (arguments 기반 studentId 전달)
import 'package:flutter/material.dart';
import '../../services/lesson_service.dart';
import '../../services/auth_service.dart';
import '../../ui/components/file_clip.dart';

class LessonHistoryScreen extends StatefulWidget {
  const LessonHistoryScreen({super.key});

  @override
  State<LessonHistoryScreen> createState() => _LessonHistoryScreenState();
}

class _LessonHistoryScreenState extends State<LessonHistoryScreen> {
  final LessonService _service = LessonService();

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  late String _studentId;
  DateTime? _from;
  DateTime? _to;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _studentId =
        (args?['studentId'] as String?) ??
        AuthService().currentStudent?.id ??
        '';
    _from = args?['from'] as DateTime?;
    _to = args?['to'] as DateTime?;

    if (_studentId.isEmpty) {
      throw Exception('LessonHistoryScreen requires studentId');
    }

    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await _service.listByStudent(_studentId, from: _from, to: _to);
    setState(() {
      _items = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('지난 수업 복습')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(child: Text('기록이 없습니다'))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = _items[i];
                final date = (m['date'] ?? '').toString();
                final subject = (m['subject'] ?? '').toString();
                final memo = (m['memo'] ?? '').toString();
                final nextPlan = (m['next_plan'] ?? '').toString();
                final List attachments = (m['attachments'] ?? []) as List;

                return ExpansionTile(
                  title: Text('$date  —  $subject'),
                  subtitle: memo.isEmpty
                      ? null
                      : Text(
                          memo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  children: [
                    if (memo.isNotEmpty)
                      ListTile(title: const Text('메모'), subtitle: Text(memo)),
                    if (nextPlan.isNotEmpty)
                      ListTile(
                        title: const Text('다음 계획'),
                        subtitle: Text(nextPlan),
                      ),
                    if (attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: attachments
                              .cast<Map>()
                              .map(
                                (a) => FileClip(
                                  name:
                                      (a['name'] ??
                                              a['path'] ??
                                              a['url'] ??
                                              '첨부')
                                          .toString(),
                                  path: (a['path'] ?? '').toString(),
                                  url: (a['url'] ?? '').toString(),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
