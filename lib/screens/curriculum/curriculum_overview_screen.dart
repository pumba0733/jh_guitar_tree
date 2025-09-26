// lib/screens/curriculum/curriculum_overview_screen.dart
// v1.39.0 | 커리큘럼 개요(트리 + 검색 + 액션 메뉴)
// - 트리 인덴트(부모-자식 기반), 검색바(제목 부분일치), 파일 열기, 배정 다이얼로그 진입
// - 다음 버전에서: 정렬/이동/편집/삭제/업로드 고도화 예정

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/curriculum_service.dart';
import 'curriculum_assign_dialog.dart';

class CurriculumOverviewScreen extends StatefulWidget {
  const CurriculumOverviewScreen({super.key});

  @override
  State<CurriculumOverviewScreen> createState() =>
      _CurriculumOverviewScreenState();
}

class _CurriculumOverviewScreenState extends State<CurriculumOverviewScreen> {
  final CurriculumService _svc = CurriculumService();
  late Future<List<Map<String, dynamic>>> _load;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load = _svc.listNodes(); // 테이블 없으면 호출부 try/catch 권장
  }

  void _refresh() {
    setState(() {
      _load = _svc.listNodes();
    });
  }

  List<_FlatNode> _buildFlatTree(List<Map<String, dynamic>> nodes) {
    // id -> node, parent_id -> children 맵 구성
    final byId = <String, Map<String, dynamic>>{};
    final children = <String?, List<Map<String, dynamic>>>{};
    for (final e in nodes) {
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      byId[id] = e;
      final pid = e['parent_id']?.toString();
      children.putIfAbsent(pid, () => []).add(e);
    }
    // created_at 오름차순 정렬(기본)
    for (final list in children.values) {
      list.sort((a, b) {
        final ca = a['created_at']?.toString() ?? '';
        final cb = b['created_at']?.toString() ?? '';
        return ca.compareTo(cb);
      });
    }
    // 루트(null parent)부터 DFS로 플랫화
    final flat = <_FlatNode>[];
    void dfs(String? pid, int depth) {
      final list = children[pid] ?? const [];
      for (final n in list) {
        final id = (n['id'] ?? '').toString();
        flat.add(_FlatNode(node: n, depth: depth));
        dfs(id, depth + 1);
      }
    }

    dfs(null, 0);
    // 검색 필터
    if (_query.trim().isEmpty) return flat;
    final q = _query.trim().toLowerCase();
    return flat
        .where(
          (e) =>
              (e.title.toLowerCase().contains(q)) ||
              (e.type.toLowerCase().contains(q)),
        )
        .toList();
  }

  Future<void> _openUrl(String url) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('웹에서는 기본 앱 실행이 제한될 수 있습니다.')),
      );
    }
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  Future<void> _assignNode(String nodeId, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => CurriculumAssignDialog(nodeId: nodeId, nodeTitle: title),
    );

    // ✅ showDialog 이후 context 사용 전 가드
    if (!mounted) return;

    if (ok == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('배정이 완료되었습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('커리큘럼 개요'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: InputDecoration(
                hintText: '검색: 제목/타입',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('불러오기에 실패했습니다\n${snap.error}'));
          }
          final nodes = snap.data ?? const [];
          if (nodes.isEmpty) {
            return const Center(child: Text('등록된 커리큘럼이 없습니다.'));
          }
          final flat = _buildFlatTree(nodes);
          return ListView.separated(
            itemCount: flat.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = flat[i];
              final n = item.node;
              final type = item.type;
              final title = item.title;
              final url = n['file_url'] as String?;
              final indent = 16.0 + (item.depth * 18.0);

              return ListTile(
                contentPadding: EdgeInsets.only(left: indent, right: 8),
                leading: Icon(
                  type == 'file' ? Icons.insert_drive_file : Icons.folder,
                ),
                title: Text(title),
                subtitle: url == null
                    ? null
                    : Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'open' && url != null) {
                      await _openUrl(url);
                    } else if (value == 'assign') {
                      await _assignNode((n['id'] ?? '').toString(), title);
                    }
                  },
                  itemBuilder: (context) => [
                    if (url != null)
                      const PopupMenuItem(
                        value: 'open',
                        child: ListTile(
                          leading: Icon(Icons.open_in_new),
                          title: Text('파일 열기'),
                          dense: true,
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'assign',
                      child: ListTile(
                        leading: Icon(Icons.person_add_alt_1),
                        title: Text('학생에게 배정'),
                        dense: true,
                      ),
                    ),
                  ],
                ),
                onTap: url == null ? null : () => _openUrl(url),
              );
            },
          );
        },
      ),
    );
  }
}

class _FlatNode {
  final Map<String, dynamic> node;
  final int depth;
  _FlatNode({required this.node, required this.depth});
  String get type => (node['type'] as String?)?.toLowerCase() ?? 'category';
  String get title => (node['title'] as String?) ?? '(제목없음)';
}
