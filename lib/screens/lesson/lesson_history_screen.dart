// lib/screens/lesson/lesson_history_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../models/lesson.dart';

class LessonHistoryScreen extends StatelessWidget {
  const LessonHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final stu = AuthService().currentStudent.value;
    if (stu == null) {
      return const Scaffold(body: Center(child: Text('학생 로그인 후 이용해주세요')));
    }
    final svc = LessonService();

    return Scaffold(
      appBar: AppBar(title: const Text('지난 수업 복습')),
      body: StreamBuilder<List<Lesson>>(
        stream: svc.streamByStudent(stu.id),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('기록이 없습니다'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final l = items[i];
              final dateStr = l.date.toIso8601String().substring(0, 10);
              return ListTile(
                title: Text(
                  l.subject?.isNotEmpty == true ? l.subject! : '(제목 없음)',
                ),
                subtitle: Text(
                  '${dateStr}  •  ${l.memo?.split('\n').firstOrNull ?? '메모 없음'}',
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text('$dateStr • ${l.subject ?? '(제목 없음)'}'),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (l.memo?.isNotEmpty == true) ...[
                              const Text(
                                '메모',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(l.memo!),
                              const SizedBox(height: 12),
                            ],
                            if (l.nextPlan?.isNotEmpty == true) ...[
                              const Text(
                                '다음 계획',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(l.nextPlan!),
                              const SizedBox(height: 12),
                            ],
                            if (l.youtubeUrl?.isNotEmpty == true) ...[
                              const Text(
                                'YouTube',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(l.youtubeUrl!),
                            ],
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('닫기'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
