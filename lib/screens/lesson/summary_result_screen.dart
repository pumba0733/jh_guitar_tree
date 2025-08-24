// lib/screens/lesson/summary_result_screen.dart
// v1.21.2 | 작성일: 2025-08-24 | 작성자: GPT
import 'package:flutter/material.dart';
import '../../services/summary_service.dart';
import '../../models/summary.dart';
import '../../services/auth_service.dart';

class SummaryResultScreen extends StatefulWidget {
  const SummaryResultScreen({super.key});

  @override
  State<SummaryResultScreen> createState() => _SummaryResultScreenState();
}

class _SummaryResultScreenState extends State<SummaryResultScreen> {
  late final SummaryService _summaryService;
  String? _summaryId;
  String? _studentId;

  @override
  void initState() {
    super.initState();
    _summaryService = SummaryService();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _summaryId = args?['summaryId'] as String?;
    _studentId =
        args?['studentId'] as String? ?? AuthService().currentStudent?.id;

    setState(() {}); // arguments 반영
  }

  Future<Summary?> _loadSummary() async {
    if (_summaryId != null) {
      return _summaryService.getById(_summaryId!);
    }
    if (_studentId != null) {
      // 가장 최신 요약 불러오기
      return _summaryService.getLatestByStudent(_studentId!);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('수업 요약 결과')),
      body: FutureBuilder<Summary?>(
        future: _loadSummary(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data == null) {
            return const Center(child: Text('요약을 찾을 수 없습니다.'));
          }
          final s = snapshot.data!;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '학생 ID: ${s.studentId}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (s.type != null) Text('유형: ${s.type}'),
              if (s.periodStart != null || s.periodEnd != null)
                Text(
                  '기간: '
                  '${s.periodStart?.toString().split(" ").first ?? "-"} ~ '
                  '${s.periodEnd?.toString().split(" ").first ?? "-"}',
                ),
              const Divider(height: 24),
              _Section(title: '학생용 요약', body: s.resultStudent),
              _Section(title: '보호자용 메시지', body: s.resultParent),
              _Section(title: '블로그용 텍스트', body: s.resultBlog),
              _Section(title: '강사용 리포트', body: s.resultTeacher),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: body == null || body!.isEmpty
            ? Text('$title: (비어있음)')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(body!),
                ],
              ),
      ),
    );
  }
}
