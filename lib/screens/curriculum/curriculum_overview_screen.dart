// lib/screens/curriculum/curriculum_overview_screen.dart
// v1.21.2 | 커리큘럼 개요(읽기 전용 최소 버전)
//
// 역할: curriculum_nodes 트리를 단순 리스트로 보여주고, file_url이 있으면 탭으로 열기
// (데스크탑 우선, 웹/모바일은 제한 안내)
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../services/curriculum_service.dart';
import 'package:url_launcher/url_launcher.dart';

class CurriculumOverviewScreen extends StatefulWidget {
  const CurriculumOverviewScreen({super.key});

  @override
  State<CurriculumOverviewScreen> createState() =>
      _CurriculumOverviewScreenState();
}

class _CurriculumOverviewScreenState extends State<CurriculumOverviewScreen> {
  final CurriculumService _svc = CurriculumService();
  late Future<List<Map<String, dynamic>>> _load;

  @override
  void initState() {
    super.initState();
    _load = _svc.listNodes();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('커리큘럼 개요')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('불러오기에 실패했습니다\\n${snap.error}'));
          }
          final nodes = snap.data ?? const [];
          if (nodes.isEmpty) {
            return const Center(child: Text('등록된 커리큘럼이 없습니다.'));
          }
          return ListView.separated(
            itemCount: nodes.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final n = nodes[i];
              final type = n['type'] as String? ?? 'category';
              final title = n['title'] as String? ?? '(제목없음)';
              final url = n['file_url'] as String?;
              final indent = (n['parent_id'] != null) ? 24.0 : 0.0;
              return ListTile(
                contentPadding: EdgeInsets.only(left: 16 + indent, right: 16),
                leading: Icon(
                  type == 'file' ? Icons.insert_drive_file : Icons.folder,
                ),
                title: Text(title),
                subtitle: url != null
                    ? Text(url, maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                onTap: url == null
                    ? null
                    : () async {
                        if (kIsWeb) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('웹에서는 기본 앱 실행이 제한될 수 있습니다.'),
                            ),
                          );
                        }
                        final uri = Uri.tryParse(url);
                        if (uri != null) {
                          await launchUrl(
                            uri,
                            mode: LaunchMode.platformDefault,
                          );
                        }
                      },
              );
            },
          );
        },
      ),
    );
  }
}
