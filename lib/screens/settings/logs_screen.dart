// lib/screens/settings/logs_screen.dart
import 'package:flutter/material.dart';
import '../../services/log_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  late Future<({List<Map<String, dynamic>> counts, List<Map<String, dynamic>> errors})> _load;

  @override
  void initState() {
    super.initState();
    _load = _loadData();
  }

  Future<({List<Map<String, dynamic>> counts, List<Map<String, dynamic>> errors})> _loadData() async {
    final counts = await LogService.fetchDailyCounts(days: 60);
    final errors = await LogService.fetchRecentErrors(limit: 50);
    return (counts: counts, errors: errors);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('로그')),
      body: FutureBuilder<({List<Map<String, dynamic>> counts, List<Map<String, dynamic>> errors})>(
        future: _load,
        builder: (c, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final counts = snap.data!.counts;
          final errors = snap.data!.errors;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('일일 집계', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...counts.map((e) => ListTile(
                    dense: true,
                    title: Text('${e['day']}'),
                    subtitle: Text('saves=${e['saves']}, errors=${e['errors']}'),
                  )),
              const Divider(),
              const Text('최근 오류', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...errors.map((e) => ListTile(
                    dense: true,
                    title: Text('${e['created_at']}  (id: ${e['id']})'),
                    subtitle: Text('${e['payload']}'),
                  )),
            ],
          );
        },
      ),
    );
  }
}
