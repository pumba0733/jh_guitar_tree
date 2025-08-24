// lib/screens/summary/lesson_summary_screen.dart
// v1.21 | 작성일: 2025-08-24 | 작성자: GPT
//
// 역할:
// - 기간/키워드 조건 선택 + 레슨 선택 후 summaries row 생성
// - SummaryService.createSummaryForSelectedLessons() 호출
//
// 주의:
// - 실제 레슨 목록 로딩/페이징은 생략한 최소 동작 버전 (listView에 mock 바인딩 지점 표시)
// - 프로젝트의 lesson_service와 연결하려면 TODO 표시된 부분만 채우면 됨

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/summary_service.dart';
import '../../models/summary.dart';
import '../../routes/app_routes.dart';

class LessonSummaryScreen extends StatefulWidget {
  const LessonSummaryScreen({super.key});

  @override
  State<LessonSummaryScreen> createState() => _LessonSummaryScreenState();
}

class _LessonSummaryScreenState extends State<LessonSummaryScreen> {
  final _formKey = GlobalKey<FormState>();

  // 조건
  String _type = '기간별'; // '기간별' | '키워드'
  DateTime? _from;
  DateTime? _to;
  final TextEditingController _keywordController = TextEditingController();
  final List<String> _keywords = [];

  // 선택 레슨
  final Set<String> _selectedLessonIds = {}; // 실제로는 lesson_service에서 받아온 id 사용

  // 필수 컨텍스트
  String? _studentId;
  String? _teacherId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      _studentId = args['studentId'] as String?;
      _teacherId = args['teacherId'] as String?;
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialFirst = _from ?? DateTime(now.year, now.month, 1);
    final initialLast = _to ?? DateTime(now.year, now.month + 1, 0);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3),
      initialDateRange: DateTimeRange(start: initialFirst, end: initialLast),
    );

    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
    }
  }

  void _addKeyword() {
    final v = _keywordController.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _keywords.add(v);
      _keywordController.clear();
    });
  }

  Future<void> _onCreatePressed() async {
    if (_studentId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('학생 정보가 없습니다. 이전 화면에서 다시 시도해주세요.')),
      );
      return;
    }
    if (_selectedLessonIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('레슨을 1개 이상 선택해주세요.')));
      return;
    }

    try {
      final Summary summary = await SummaryService.instance
          .createSummaryForSelectedLessons(
            studentId: _studentId!,
            teacherId: _teacherId,
            type: _type,
            periodStart: _type == '기간별' ? _from : null,
            periodEnd: _type == '기간별' ? _to : null,
            keywords: _type == '키워드' ? _keywords : null,
            selectedLessonIds: _selectedLessonIds.toList(),
          );

      if (!mounted) return;

      // 결과 화면으로 이동
      Navigator.of(context).pushNamed(
        AppRoutes.summaryResult, // '/summary_result'로 매핑되어 있어야 함
        arguments: {'summaryId': summary.id},
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('요약 생성 실패: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('yyyy.MM.dd');

    return Scaffold(
      appBar: AppBar(title: const Text('수업 요약')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 타입 선택
            Row(
              children: [
                const Text('유형: '),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _type,
                  items: const [
                    DropdownMenuItem(value: '기간별', child: Text('기간별')),
                    DropdownMenuItem(value: '키워드', child: Text('키워드')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _type = v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 기간별
            if (_type == '기간별') ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _pickDateRange,
                      child: Text(
                        (_from != null && _to != null)
                            ? '${df.format(_from!)} ~ ${df.format(_to!)}'
                            : '기간 선택',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // 키워드형
            if (_type == '키워드') ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _keywordController,
                      decoration: const InputDecoration(
                        labelText: '키워드 추가',
                        hintText: '예: 박자, 피킹, 코드 체인지',
                      ),
                      onSubmitted: (_) => _addKeyword(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _addKeyword,
                    child: const Text('추가'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _keywords
                    .map(
                      (k) => Chip(
                        label: Text(k),
                        onDeleted: () {
                          setState(() => _keywords.remove(k));
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
            ],

            const Divider(height: 32),

            // 레슨 선택 리스트 (최소 구현: 임시 아이템)
            // 실제 연동 시: lesson_service.list(...) 결과로 대체
            const Text('레슨 선택', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...List.generate(8, (i) {
              final id = 'mock-lesson-$i'; // TODO: 실제 lesson id로 교체
              final selected = _selectedLessonIds.contains(id);
              return CheckboxListTile(
                value: selected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedLessonIds.add(id);
                    } else {
                      _selectedLessonIds.remove(id);
                    }
                  });
                },
                title: Text('레슨 #$i  |  예시 주제'),
                subtitle: const Text('YYYY.MM.DD · 간단 메모'),
              );
            }),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _onCreatePressed,
                icon: const Icon(Icons.summarize),
                label: const Text('요약 생성'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
