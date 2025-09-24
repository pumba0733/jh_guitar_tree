// lib/screens/curriculum/curriculum_browser_screen.dart
// v1.73.1-ui | 커리큘럼 다중선택(체크박스) + 선택 배정 / 학생 다이얼로그 '전체 선택' + 악기표시 + 가나다정렬
// CHG: '오늘 레슨에 노드 링크' / '오늘 레슨에 링크' 기능 및 버튼 제거
//
// 의존:
// - models: curriculum.dart, resource.dart, student.dart
// - services: curriculum_service.dart, resource_service.dart, file_service.dart, student_service.dart
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

class CurriculumBrowserScreen extends StatefulWidget {
  const CurriculumBrowserScreen({super.key});

  @override
  State<CurriculumBrowserScreen> createState() =>
      _CurriculumBrowserScreenState();
}

class _CurriculumBrowserScreenState extends State<CurriculumBrowserScreen> {
  final _svc = CurriculumService();
  final _resSvc = ResourceService();
  late Future<List<Map<String, dynamic>>> _load;

  CurriculumNode? _selected; // 우측 패널 상세 표시용 (단일 선택)
  Future<List<ResourceFile>>? _resLoad; // 선택 노드 리소스

  // === 좌측 트리 다중선택 ===
  final Set<String> _selectedNodeIds = <String>{};

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

  // === 학생 선택 다이얼로그 호출 ===
  Future<_StudentPickResult?> _pickStudentsDialog() {
    return showDialog<_StudentPickResult>(
      context: context,
      builder: (_) => const _StudentPickerDialog(),
    );
  }

  // === 단일 노드 배정 (기존 유지) ===
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

  // === 다중 선택된 노드 일괄 배정 ===
  Future<void> _assignSelectedNodesToStudents() async {
    if (_selectedNodeIds.isEmpty) return;
    final picked = await _pickStudentsDialog();
    if (picked == null || picked.selected.isEmpty) return;

    int ok = 0, fail = 0;
    // 노드 × 학생 조합으로 모두 배정
    for (final nodeId in _selectedNodeIds) {
      for (final stu in picked.selected) {
        try {
          await _svc.assignNodeToStudent(studentId: stu.id, nodeId: nodeId);
          ok++;
        } catch (_) {
          fail++;
        }
      }
    }
    if (!mounted) return;
    final msg = fail == 0 ? '배정 완료 ($ok건)' : '일부 실패: 성공 $ok / 실패 $fail';
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
    final selectedCount = _selectedNodeIds.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('커리큘럼 브라우저 (강사)'),
        actions: [
          if (selectedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '선택: $selectedCount개',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          // === 선택 배정 버튼 ===
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: selectedCount == 0
                  ? null
                  : _assignSelectedNodesToStudents,
              icon: const Icon(Icons.assignment_turned_in),
              label: const Text('선택 배정'),
            ),
          ),
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
                hideRootFiles: true, // ✅ 루트파일 숨김
                onTapTitle: _selectNode,
                // === 체크박스 핸들러 전달 ===
                isChecked: (id) => _selectedNodeIds.contains(id),
                onToggleCheck: (id, v) {
                  setState(() {
                    if (v == true) {
                      _selectedNodeIds.add(id);
                    } else {
                      _selectedNodeIds.remove(id);
                    }
                  });
                },
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
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: () => _assignToStudents(n),
                            icon: const Icon(Icons.assignment_ind),
                            label: const Text('학생에게 배정'),
                          ),
                          // NOTE: '오늘 레슨에 노드 링크' 버튼 제거됨
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
                                            // NOTE: '오늘 레슨에 링크' 아이콘 버튼 제거됨
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
              SizedBox(width: 480, child: leftTree()),
              const VerticalDivider(width: 1),
              Expanded(child: rightPane()),
            ],
          );
        },
      ),
    );
  }
}

// ======================= 트리(체크박스 포함) =======================

class _Tree extends StatelessWidget {
  final Map<String?, List<CurriculumNode>> byParent;
  final bool hideRootFiles;

  // 타이틀 클릭 시 우측 패널용 단일 선택 (기존 onTap 동작 대체)
  final ValueChanged<CurriculumNode> onTapTitle;

  // 체크박스 상태/토글
  final bool Function(String id) isChecked;
  final void Function(String id, bool? value) onToggleCheck;

  const _Tree({
    required this.byParent,
    required this.onTapTitle,
    required this.isChecked,
    required this.onToggleCheck,
    this.hideRootFiles = false,
  });

  @override
  Widget build(BuildContext context) => _build(context, null, 0);

  Widget _build(BuildContext context, String? parentId, int depth) {
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
            contentPadding: EdgeInsets.only(left: 12 + 16.0 * depth, right: 8),
            leading: Checkbox(
              value: isChecked(n.id),
              onChanged: (v) => onToggleCheck(n.id, v),
            ),
            title: Row(
              children: [
                Icon(
                  n.type == 'file' ? Icons.insert_drive_file : Icons.folder,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(n.title)),
              ],
            ),
            // 타이틀 영역 탭 → 우측 패널 상세 선택
            onTap: () => onTapTitle(n),
          ),
          if ((byParent[n.id] ?? const <CurriculumNode>[]).isNotEmpty)
            _build(context, n.id, depth + 1),
          const Divider(height: 1),
        ],
      ],
    );
  }
}

// ======================= 학생 선택 다이얼로그 =======================

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

  bool _selectAll = false; // === 전체 선택 토글

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

  void _applySelectAll(List<Student> items, bool value) {
    setState(() {
      _selectAll = value;
      if (value) {
        for (final s in items) {
          _selected[s.id] = s;
        }
      } else {
        // 현재 필터로 보이는 학생만 선택 해제
        for (final s in items) {
          _selected.remove(s.id);
        }
      }
    });
  }

  String _instrumentLabel(Student s) {
    // Student에 instrument가 없으면 빈 문자열
    try {
      // ignore: unnecessary_cast
      final any = s as dynamic;
      final v = any.instrument as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('학생 선택'),
      content: SizedBox(
        width: 560,
        height: 560,
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
            // === 전체 선택 스위치 ===
            Row(
              children: [
                Switch(
                  value: _selectAll,
                  onChanged: (v) {
                    // 리스트가 로딩된 뒤에만 실제 반영하므로 여기서는 토글만 갱신
                    setState(() {
                      _selectAll = v;
                    });
                  },
                ),
                const Text('전체 선택'),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: FutureBuilder<List<Student>>(
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

                  // === 가나다순 정렬 ===
                  items.sort((a, b) => a.name.compareTo(b.name));

                  // 전체 선택 토글 반영 (리스트가 새로 로드될 때 동기화)
                  if (_selectAll) {
                    for (final s in items) {
                      _selected[s.id] = s;
                    }
                  }

                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = items[i];
                      final checked = _selected.containsKey(s.id);
                      final phone4 = s.phoneLast4 ?? '';
                      final memo = s.memo ?? '';
                      final inst = _instrumentLabel(s);
                      final parts = <String>[];
                      if (inst.isNotEmpty) parts.add('악기 $inst');
                      if (phone4.isNotEmpty) parts.add('전화끝 $phone4');
                      if (memo.isNotEmpty) parts.add(memo);
                      final subtitle = parts.join(' · ');

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
