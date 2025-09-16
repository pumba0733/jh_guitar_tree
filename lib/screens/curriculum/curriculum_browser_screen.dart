// lib/screens/curriculum/curriculum_browser_screen.dart
// v1.45.0 | 강사용 브라우저 - '오늘 레슨에 링크' 액션 추가 + v1.45 가시 트리 호환
// - CurriculumService.listNodes()가 서버 RPC(list_visible_curriculum_tree) 우선 사용 (서비스에서 처리)
// - 노드/리소스 선택 후 '학생 선택' → 오늘 레슨에 node/resource 링크 삽입
// - 기존 '학생에게 배정' 기능 유지
//
// 의존:
// - models: curriculum.dart, resource.dart, student.dart
// - services: curriculum_service.dart, resource_service.dart, file_service.dart, student_service.dart, lesson_links_service.dart
// - packages: url_launcher

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/curriculum.dart';
import '../../models/resource.dart';
import '../../models/student.dart';
import '../../services/curriculum_service.dart';
import '../../services/resource_service.dart';
import '../../services/file_service.dart';
import '../../services/student_service.dart';
import '../../services/lesson_links_service.dart';

class CurriculumBrowserScreen extends StatefulWidget {
  const CurriculumBrowserScreen({super.key});

  @override
  State<CurriculumBrowserScreen> createState() =>
      _CurriculumBrowserScreenState();
}

class _CurriculumBrowserScreenState extends State<CurriculumBrowserScreen> {
  final _svc = CurriculumService();
  final _resSvc = ResourceService();
  final _links = LessonLinksService();
  late Future<List<Map<String, dynamic>>> _load;

  CurriculumNode? _selected;
  Future<List<ResourceFile>>? _resLoad; // 선택 노드 리소스

  @override
  void initState() {
    super.initState();
    _load = _svc.listNodes();
  }

  Future<void> _refresh() async {
    final f = _svc.listNodes();
    if (!mounted) return;
    setState(() => _load = f);
    await f;
  }

  void _selectNode(CurriculumNode n) {
    setState(() {
      _selected = n;
      _resLoad = _resSvc.listByNode(n.id);
    });
  }

  Future<_StudentPickResult?> _pickStudentsDialog() {
    return showDialog<_StudentPickResult>(
      context: context,
      builder: (_) => const _StudentPickerDialog(),
    );
  }

  Future<void> _assignToStudents(CurriculumNode node) async {
    final picked = await _pickStudentsDialog();
    if (picked == null || picked.selected.isEmpty) return;

    int ok = 0, fail = 0;
    for (final stu in picked.selected) {
      try {
        await _svc.assignNodeToStudent(studentId: stu.id, nodeId: node.id);
        ok++;
      } catch (_) {
        fail++;
      }
    }
    if (!mounted) return;
    final msg = fail == 0 ? '배정 완료 ($ok명)' : '일부 실패: 성공 $ok / 실패 $fail';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // === NEW: 오늘 레슨 링크 액션 ===
  Future<void> _linkNodeToTodayLesson(CurriculumNode node) async {
    final picked = await _pickStudentsDialog();
    if (picked == null || picked.selected.isEmpty) return;

    int ok = 0, fail = 0;
    for (final stu in picked.selected) {
      final success = await _links.sendNodeToTodayLesson(
        studentId: stu.id,
        nodeId: node.id,
      );
      if (success) {
        ok++;
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    final msg = fail == 0 ? '오늘 레슨 링크 완료 ($ok명)' : '일부 실패: 성공 $ok / 실패 $fail';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _linkResourceToTodayLesson(ResourceFile r) async {
    final picked = await _pickStudentsDialog();
    if (picked == null || picked.selected.isEmpty) return;

    int ok = 0, fail = 0;
    for (final stu in picked.selected) {
      final success = await _links.sendResourceToTodayLesson(
        studentId: stu.id,
        resource: r,
      );
      if (success) {
        ok++;
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    final msg = fail == 0 ? '리소스 링크 완료 ($ok명)' : '일부 실패: 성공 $ok / 실패 $fail';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openNodeLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  Future<void> _openResource(ResourceFile r) async {
    try {
      final url = await _resSvc.signedUrl(r); // private 버킷도 허용
      await FileService.instance.openSmart(url: url, name: r.filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파일 열기 실패\n$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final split = MediaQuery.of(context).size.width >= 880;
    return Scaffold(
      appBar: AppBar(
        title: const Text('커리큘럼 브라우저 (강사)'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('로드 실패\n${snap.error}'));
          }

          final nodes = (snap.data ?? [])
              .map((e) => CurriculumNode.fromMap(Map<String, dynamic>.from(e)))
              .toList();

          final byParent = <String?, List<CurriculumNode>>{};
          for (final n in nodes) {
            byParent.putIfAbsent(n.parentId, () => []).add(n);
          }
          for (final list in byParent.values) {
            list.sort((a, b) => a.order.compareTo(b.order));
          }

          Widget leftTree() => ListView(
            children: [
              _Tree(
                byParent: byParent,
                onTap: _selectNode,
                hideRootFiles: true, // ✅ 루트파일 숨김
              ),
            ],
          );

          Widget rightPane() {
            final n = _selected;
            if (n == null) {
              return const Center(child: Text('왼쪽에서 항목을 선택하세요.'));
            }
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '유형: ${n.type} • order=${n.order}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),

                      if (n.fileUrl != null)
                        FilledButton.icon(
                          onPressed: () => _openNodeLink(n.fileUrl!),
                          icon: const Icon(Icons.open_in_new),
                          label: Text(kIsWeb ? '링크 열기 (웹)' : '링크/파일 열기'),
                        ),

                      const SizedBox(height: 12),
                      // === NEW: 오늘 레슨에 노드 링크 ===
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: () => _assignToStudents(n),
                            icon: const Icon(Icons.assignment_ind),
                            label: const Text('학생에게 배정'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _linkNodeToTodayLesson(n),
                            icon: const Icon(Icons.link),
                            label: const Text('오늘 레슨에 노드 링크'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),
                      Text(
                        '리소스',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _resLoad == null
                            ? const Center(child: Text('리소스가 없습니다.'))
                            : FutureBuilder<List<ResourceFile>>(
                                future: _resLoad,
                                builder: (context, rs) {
                                  if (rs.connectionState !=
                                      ConnectionState.done) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }
                                  if (rs.hasError) {
                                    return Center(
                                      child: Text('리소스 로드 실패\n${rs.error}'),
                                    );
                                  }
                                  final items =
                                      rs.data ?? const <ResourceFile>[];
                                  if (items.isEmpty) {
                                    return const Center(
                                      child: Text('이 노드에 연결된 리소스가 없습니다.'),
                                    );
                                  }
                                  return ListView.separated(
                                    itemCount: items.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (_, i) {
                                      final r = items[i];
                                      final subtitle =
                                          '${r.storageBucket}/${r.storagePath}';
                                      return ListTile(
                                        leading: const Icon(Icons.description),
                                        title: Text(
                                          r.title?.isNotEmpty == true
                                              ? r.title!
                                              : r.filename,
                                        ),
                                        subtitle: Text(
                                          subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: () => _openResource(r),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip: '열기',
                                              onPressed: () => _openResource(r),
                                              icon: const Icon(
                                                Icons.open_in_new,
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: '오늘 레슨에 링크',
                                              onPressed: () =>
                                                  _linkResourceToTodayLesson(r),
                                              icon: const Icon(
                                                Icons.link_outlined,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          if (!split) {
            return Column(
              children: [
                Expanded(child: leftTree()),
                const Divider(height: 1),
                SizedBox(height: 340, child: rightPane()),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 420, child: leftTree()),
              const VerticalDivider(width: 1),
              Expanded(child: rightPane()),
            ],
          );
        },
      ),
    );
  }
}

class _Tree extends StatelessWidget {
  final Map<String?, List<CurriculumNode>> byParent;
  final ValueChanged<CurriculumNode> onTap;
  final bool hideRootFiles;
  const _Tree({
    required this.byParent,
    required this.onTap,
    this.hideRootFiles = false,
  });

  @override
  Widget build(BuildContext context) => _build(null, 0);

  Widget _build(String? parentId, int depth) {
    var list = [...(byParent[parentId] ?? const <CurriculumNode>[])];
    // ✅ 루트에서 type == 'file' 숨김
    if (hideRootFiles && parentId == null) {
      list = list.where((n) => n.type != 'file').toList();
    }
    list.sort((a, b) => a.order.compareTo(b.order));

    return Column(
      children: [
        for (final n in list) ...[
          ListTile(
            contentPadding: EdgeInsets.only(left: 16 + 16.0 * depth, right: 8),
            leading: Icon(
              n.type == 'file' ? Icons.insert_drive_file : Icons.folder,
            ),
            title: Text(n.title),
            onTap: () => onTap(n),
          ),
          if ((byParent[n.id] ?? const <CurriculumNode>[]).isNotEmpty)
            _build(n.id, depth + 1),
          const Divider(height: 1),
        ],
      ],
    );
  }
}

// ===== 학생 선택 다이얼로그 =====

class _StudentPickResult {
  final List<Student> selected;
  const _StudentPickResult(this.selected);
}

class _StudentPickerDialog extends StatefulWidget {
  const _StudentPickerDialog();

  @override
  State<_StudentPickerDialog> createState() => _StudentPickerDialogState();
}

class _StudentPickerDialogState extends State<_StudentPickerDialog> {
  final _svc = StudentService();
  final _query = TextEditingController();
  final _selected = <String, Student>{};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _toggle(Student s) {
    setState(() {
      if (_selected.containsKey(s.id)) {
        _selected.remove(s.id);
      } else {
        _selected[s.id] = s;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('학생 선택'),
      content: SizedBox(
        width: 520,
        height: 520,
        child: Column(
          children: [
            TextField(
              controller: _query,
              decoration: const InputDecoration(
                hintText: '이름 검색 (최대 100명)',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<Student>>(
                // ✅ StudentService.list(query) 사용
                future: _svc.list(query: _query.text.trim(), limit: 100),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(child: Text('학생 목록 로드 실패\n${snap.error}'));
                  }
                  var items = snap.data ?? const <Student>[];
                  if (items.isEmpty) {
                    return const Center(child: Text('표시할 학생이 없습니다.'));
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = items[i];
                      final checked = _selected.containsKey(s.id);
                      final phone4 = s.phoneLast4 ?? '';
                      final memo = s.memo ?? '';
                      final subtitle = [
                        if (phone4.isNotEmpty) '전화끝 $phone4',
                        if (memo.isNotEmpty) memo,
                      ].join(' · ');

                      return ListTile(
                        leading: Checkbox(
                          value: checked,
                          onChanged: (_) => _toggle(s),
                        ),
                        title: Text(s.name), // non-null
                        subtitle: subtitle.isEmpty
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => _toggle(s),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _StudentPickResult(_selected.values.toList()),
            );
          },
          child: const Text('확인'),
        ),
      ],
    );
  }
}
