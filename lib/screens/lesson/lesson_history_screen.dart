import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:jh_guitar_tree/data/local_hive_boxes.dart';
import 'package:jh_guitar_tree/models/lesson.dart';

class LessonHistoryScreen extends StatefulWidget {
  const LessonHistoryScreen({super.key});

  @override
  State<LessonHistoryScreen> createState() => _LessonHistoryScreenState();
}

class _LessonHistoryScreenState extends State<LessonHistoryScreen> {
  late Box<Lesson> _lessonBox;
  List<bool> isExpandedList = [];

  @override
  void initState() {
    super.initState();
    _lessonBox = LocalHiveBoxes.getLessonBox();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📚 지난 수업 복습')),
      body: ValueListenableBuilder(
        valueListenable: _lessonBox.listenable(),
        builder: (context, Box<Lesson> box, _) {
          final lessons =
              box.values.toList()
                ..sort((a, b) => b.date.compareTo(a.date)); // 최신순 정렬

          if (lessons.isEmpty) {
            return const Center(child: Text('저장된 수업이 없습니다.'));
          }

          isExpandedList = List.filled(lessons.length, false);

          return ListView.builder(
            itemCount: lessons.length,
            itemBuilder: (context, index) {
              final lesson = lessons[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                child: ExpansionTile(
                  title: Text('${lesson.date} - ${lesson.subject}'),
                  subtitle: Text('주제: ${lesson.keywords.join(', ')}'),
                  initiallyExpanded: isExpandedList[index],
                  onExpansionChanged: (expanded) {
                    setState(() {
                      isExpandedList[index] = expanded;
                    });
                  },
                  children: [
                    ListTile(
                      title: const Text('📝 수업 메모'),
                      subtitle: Text(lesson.memo),
                    ),
                    ListTile(
                      title: const Text('📌 다음 계획'),
                      subtitle: Text(lesson.nextPlan),
                    ),
                    if (lesson.youtubeUrl.isNotEmpty)
                      ListTile(
                        title: const Text('🎥 유튜브 링크'),
                        subtitle: Text(lesson.youtubeUrl),
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('유튜브 열기: ${lesson.youtubeUrl}'),
                            ),
                          );
                        },
                      ),
                    if (lesson.audioPaths.isNotEmpty)
                      ListTile(
                        title: const Text('📎 첨부 파일'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children:
                              lesson.audioPaths.map((file) {
                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(file),
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: () {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text('파일 실행: $file'),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                );
                              }).toList(),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
