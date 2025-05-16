import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/lesson.dart';
import 'package:jh_guitar_tree/data/local_hive_boxes.dart';
import 'package:jh_guitar_tree/services/firestore_service.dart';
import 'package:jh_guitar_tree/ui/components/save_status_indicator.dart';

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _memoController = TextEditingController();
  final TextEditingController _nextPlanController = TextEditingController();
  final TextEditingController _youtubeController = TextEditingController();

  List<String> selectedKeywords = [];
  List<String> allKeywords = ['박자 맞추기', '코드 전환', '리듬', '스트럼', '소리 내기', '강약 조절'];

  bool showKeywordSelector = false;
  SaveStatus _saveStatus = SaveStatus.saved;
  DateTime? _lastSavedTime;

  @override
  void initState() {
    super.initState();
    _subjectController.addListener(_autoSave);
    _memoController.addListener(_autoSave);
    _nextPlanController.addListener(_autoSave);
    _youtubeController.addListener(_autoSave);
  }

  void _toggleKeyword(String keyword) {
    setState(() {
      if (selectedKeywords.contains(keyword)) {
        selectedKeywords.remove(keyword);
      } else {
        selectedKeywords.add(keyword);
      }
    });
    _autoSave();
  }

  Future<void> _autoSave() async {
    setState(() => _saveStatus = SaveStatus.saving);
    try {
      final lesson = Lesson(
        studentId: 's001',
        date: '2025-05-16',
        subject: _subjectController.text,
        keywords: selectedKeywords,
        memo: _memoController.text,
        nextPlan: _nextPlanController.text,
        audioPaths: [], // 추후 추가
        youtubeUrl: _youtubeController.text,
      );

      final box = LocalHiveBoxes.getLessonBox();
      await box.put('${lesson.studentId}_${lesson.date}', lesson);
      await FirestoreService.saveLessonToFirestore(lesson);

      setState(() {
        _saveStatus = SaveStatus.saved;
        _lastSavedTime = DateTime.now();
      });
    } catch (_) {
      setState(() => _saveStatus = SaveStatus.failed);
    }
  }

  void _openYoutubeLink() {
    final url = _youtubeController.text.trim();
    if (url.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('유튜브 링크 열기: $url')));
    }
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _memoController.dispose();
    _nextPlanController.dispose();
    _youtubeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📝 오늘 수업 보기')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(labelText: '수업 주제 입력'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.label),
              label: const Text('수업 주제 키워드 선택'),
              onPressed: () {
                setState(() => showKeywordSelector = !showKeywordSelector);
              },
            ),
            if (showKeywordSelector)
              Wrap(
                spacing: 8,
                children:
                    allKeywords.map((keyword) {
                      final selected = selectedKeywords.contains(keyword);
                      return FilterChip(
                        label: Text(keyword),
                        selected: selected,
                        onSelected: (_) => _toggleKeyword(keyword),
                      );
                    }).toList(),
              ),

            const SizedBox(height: 24),
            TextField(
              controller: _youtubeController,
              decoration: const InputDecoration(labelText: '유튜브 링크'),
              onSubmitted: (_) => _openYoutubeLink(),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _openYoutubeLink,
              child: const Text('링크 열기'),
            ),

            const SizedBox(height: 24),
            TextField(
              controller: _memoController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '✏️ 수업 메모 입력',
                alignLabelWithHint: true,
              ),
            ),

            const SizedBox(height: 24),
            TextField(
              controller: _nextPlanController,
              decoration: const InputDecoration(labelText: '📌 다음 수업 계획'),
            ),

            const SizedBox(height: 32),
            SaveStatusIndicator(
              status: _saveStatus,
              lastSavedTime: _lastSavedTime,
            ),
          ],
        ),
      ),
    );
  }
}
