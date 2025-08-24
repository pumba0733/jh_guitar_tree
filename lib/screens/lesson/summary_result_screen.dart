// lib/screens/lesson/summary_result_screen.dart
import 'package:flutter/material.dart';
import '../../services/summary_service.dart';
import '../../models/summary.dart';

class SummaryResultScreen extends StatefulWidget {
  const SummaryResultScreen({super.key});

  @override
  State<SummaryResultScreen> createState() => _SummaryResultScreenState();
}

class _SummaryResultScreenState extends State<SummaryResultScreen> {
  final _svc = SummaryService();
  Summary? _item;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = ModalRoute.of(context)?.settings.arguments as String?;
    if (id == null) {
      setState(() {
        _loading = false;
        _item = null;
      });
      return;
    }
    _load(id);
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final s = await _svc.getById(id);
      setState(() => _item = s);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('요약 결과')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _item == null
              ? const Center(child: Text('요약을 찾을 수 없습니다.'))
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ListView(
                    children: [
                      Text('요약 타입: ${_item!.type}'),
                      const SizedBox(height: 8),
                      const Divider(),
                      const Text('학생용', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_item!.resultStudent ?? '없음'),
                      const SizedBox(height: 12),
                      const Text('보호자용', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_item!.resultParent ?? '없음'),
                      const SizedBox(height: 12),
                      const Text('블로그용', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_item!.resultBlog ?? '없음'),
                      const SizedBox(height: 12),
                      const Text('강사용', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(_item!.resultTeacher ?? '없음'),
                    ],
                  ),
                ),
    );
  }
}
