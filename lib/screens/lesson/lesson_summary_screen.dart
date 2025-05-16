import 'package:flutter/material.dart';

class LessonSummaryScreen extends StatefulWidget {
  const LessonSummaryScreen({super.key});

  @override
  State<LessonSummaryScreen> createState() => _LessonSummaryScreenState();
}

class _LessonSummaryScreenState extends State<LessonSummaryScreen> {
  String selectedCondition = '기간별';
  final TextEditingController _keywordController = TextEditingController();

  final List<Map<String, dynamic>> mockLessons = [
    {'id': 'lesson1', 'date': '2025-05-10', 'subject': '스트럼 리듬 연습'},
    {'id': 'lesson2', 'date': '2025-05-14', 'subject': 'Let it be 도입부'},
  ];

  final Set<String> selectedLessonIds = {};

  void _toggleLesson(String lessonId) {
    setState(() {
      if (selectedLessonIds.contains(lessonId)) {
        selectedLessonIds.remove(lessonId);
      } else {
        selectedLessonIds.add(lessonId);
      }
    });
  }

  void _requestSummary() {
    if (selectedLessonIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('요약할 수업을 선택해주세요.')));
      return;
    }

    // 🔁 AI 요청은 나중에 연동
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SummaryResultScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📈 수업 요약 요청')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 조건 선택
            Row(
              children: [
                const Text('조건: '),
                DropdownButton<String>(
                  value: selectedCondition,
                  items:
                      ['기간별', '키워드'].map((e) {
                        return DropdownMenuItem(value: e, child: Text(e));
                      }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => selectedCondition = val);
                    }
                  },
                ),
                const SizedBox(width: 16),
                if (selectedCondition == '키워드')
                  Expanded(
                    child: TextField(
                      controller: _keywordController,
                      decoration: const InputDecoration(hintText: '키워드 입력'),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // 수업 리스트
            Expanded(
              child: ListView.builder(
                itemCount: mockLessons.length,
                itemBuilder: (context, index) {
                  final lesson = mockLessons[index];
                  final selected = selectedLessonIds.contains(lesson['id']);
                  return ListTile(
                    title: Text('${lesson['date']} - ${lesson['subject']}'),
                    trailing: Checkbox(
                      value: selected,
                      onChanged: (_) => _toggleLesson(lesson['id']),
                    ),
                  );
                },
              ),
            ),

            ElevatedButton(
              onPressed: _requestSummary,
              child: const Text('요약 요청 및 저장'),
            ),
          ],
        ),
      ),
    );
  }
}

// 👉 결과 화면 틀만 제공 (나중에 AI 결과 연동)
class SummaryResultScreen extends StatelessWidget {
  const SummaryResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📄 요약 결과')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('학생용 요약', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('🎸 리듬 연습을 잘 마쳤어요! 다음엔 업스트럼 강화!'),
            SizedBox(height: 20),
            Text('보호자용 메시지', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('이번 주는 스트럼 리듬 연습을 진행했습니다.'),
            SizedBox(height: 20),
            Text('블로그용 텍스트', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('#리듬 #스트럼 #LetItBe #연습'),
            SizedBox(height: 20),
            Text('강사용 리포트', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('학생의 리듬 감각이 향상됨. 스트럼 시 강약 구분도 좋아짐.'),
          ],
        ),
      ),
    );
  }
}
