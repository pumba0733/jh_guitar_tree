// lib/screens/curriculum/student_curriculum_screen.dart
// v1.43.1 | 학생별 진행 + 오늘 레슨으로 보내기
// - 배정 목록 + 완료 토글 + 상단 집계 유지
// - 각 항목에 '오늘 레슨으로 보내기' 버튼 추가
//   · 노드 자체 전송 또는 리소스 선택 전송 (바텀시트)
// - LessonLinksService 미구현/SQL 미적용 시 no-op 안내

import 'package:flutter/material.dart';

import '../../services/curriculum_service.dart';
import '../../services/progress_service.dart';
import '../../services/resource_service.dart';
import '../../services/lesson_links_service.dart';
import '../../services/file_service.dart';

import '../../models/curriculum.dart';
import '../../models/resource.dart';

class StudentCurriculumScreen extends StatefulWidget {
  final String studentId;
  const StudentCurriculumScreen({super.key, required this.studentId});

  @override
  State<StudentCurriculumScreen> createState() =>
      _StudentCurriculumScreenState();
}

class _StudentCurriculumScreenState extends State<StudentCurriculumScreen> {
  final _svc = CurriculumService();
  final _progress = ProgressService();
  final _resSvc = ResourceService();
  final _links = LessonLinksService();

  late Future<
    ({
      List<CurriculumAssignment> assigns,
      Map<String, CurriculumNode> nodeMap,
      Map<String, bool> doneMap,
    })
  >
  _load;

  @override
  void initState() {
    super.initState();
    _load = _fetch();
  }

  Future<
    ({
      List<CurriculumAssignment> assigns,
      Map<String, CurriculumNode> nodeMap,
      Map<String, bool> doneMap,
    })
  >
  _fetch() async {
    final nodesRaw = await _svc.listNodes();
    final nodes = nodesRaw
        .map((e) => CurriculumNode.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    final nodeMap = {for (final n in nodes) n.id: n};

    final assignsRaw = await _svc.listAssignmentsByStudent(widget.studentId);
    final assigns = assignsRaw
        .map((e) => CurriculumAssignment.fromMap(Map<String, dynamic>.from(e)))
        .toList();

    final doneMap = await _progress.mapByStudent(widget.studentId);
    return (assigns: assigns, nodeMap: nodeMap, doneMap: doneMap);
  }

  Future<void> _refresh() async {
    final f = _fetch();
    if (!mounted) return;
    setState(() => _load = f);
    await f;
  }

  Future<void> _toggle(String nodeId) async {
    final ok = await _progress.toggle(
      studentId: widget.studentId,
      nodeId: nodeId,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('진도 테이블이 아직 준비되지 않았습니다. SQL Δ 적용 필요.')),
      );
    }
    await _refresh();
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

  Future<void> _sendToTodayLesson({
    required String nodeId,
    required String nodeTitle,
  }) async {
    // 리소스 불러오고 바텀시트에서 선택
    final resFuture = _resSvc.listByNode(nodeId);
    if (!mounted) return;
    final result = await showModalBottomSheet<_SendChoice>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) =>
          _SendChooserSheet(title: nodeTitle, resourcesFuture: resFuture),
    );
    if (result == null) return;

    bool ok = false;
    try {
      if (result.kind == _SendKind.node) {
        ok = await _links.sendNodeToTodayLesson(
          studentId: widget.studentId,
          nodeId: nodeId,
        );
      } else if (result.kind == _SendKind.resource && result.resource != null) {
        ok = await _links.sendResourceToTodayLesson(
          studentId: widget.studentId,
          resource: result.resource!,
        );
      }
    } catch (e) {
      ok = false;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '오늘 레슨으로 보냈어요.' : '전송 실패 또는 미구현(SQL Δ 필요)')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('학생 커리큘럼'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body:
          FutureBuilder<
            ({
              List<CurriculumAssignment> assigns,
              Map<String, CurriculumNode> nodeMap,
              Map<String, bool> doneMap,
            })
          >(
            future: _load,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('로드 실패\n${snap.error}'));
              }
              final data = snap.data!;
              if (data.assigns.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '배정된 커리큘럼이 없습니다.\n강사에게 배정을 요청하세요.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              // 집계
              final total = data.assigns.length;
              final doneCount = data.assigns
                  .where((a) => data.doneMap[a.curriculumNodeId] == true)
                  .length;

              return Column(
                children: [
                  // 상단 집계 바
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border(
                        bottom: BorderSide(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.insights,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '완료 $doneCount / $total',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        Text(
                          doneCount == total
                              ? '완료됨'
                              : '${(((doneCount / total) * 100)).toStringAsFixed(0)}%',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: data.assigns.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final a = data.assigns[i];
                        final n = data.nodeMap[a.curriculumNodeId];
                        final title = n?.title ?? '(삭제된 항목)';
                        final done = data.doneMap[a.curriculumNodeId] ?? false;

                        return _AssignmentTile(
                          title: title,
                          pathSegments: a.path ?? const [],
                          done: done,
                          onToggle: () => _toggle(a.curriculumNodeId),
                          onFetchResources: () =>
                              _resSvc.listByNode(a.curriculumNodeId),
                          onOpenResource: _openResource,
                          onSendToTodayLesson: () => _sendToTodayLesson(
                            nodeId: a.curriculumNodeId,
                            nodeTitle: title,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

// ====== 전송 선택 바텀시트 ======

enum _SendKind { node, resource }

class _SendChoice {
  final _SendKind kind;
  final ResourceFile? resource;
  const _SendChoice.node() : kind = _SendKind.node, resource = null;
  const _SendChoice.resource(this.resource) : kind = _SendKind.resource;
}

class _SendChooserSheet extends StatelessWidget {
  final String title;
  final Future<List<ResourceFile>> resourcesFuture;

  // 기존: const _SendChooserSheet({ super.key, required this.title, required this.resourcesFuture });
  const _SendChooserSheet({required this.title, required this.resourcesFuture});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Scaffold(
            appBar: AppBar(
              title: Text('오늘 레슨으로 보내기 · $title'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.send),
                  title: const Text('노드 자체 보내기'),
                  subtitle: const Text('이 커리큘럼 항목을 오늘 레슨 링크로 추가'),
                  onTap: () => Navigator.pop(context, const _SendChoice.node()),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    '리소스에서 선택',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<ResourceFile>>(
                    future: resourcesFuture,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) {
                        return Center(child: Text('리소스 로드 실패\n${snap.error}'));
                      }
                      final items = snap.data ?? const <ResourceFile>[];
                      if (items.isEmpty) {
                        return const Center(child: Text('연결된 리소스가 없습니다.'));
                      }
                      return ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = items[i];
                          return ListTile(
                            leading: const Icon(Icons.description),
                            title: Text(
                              r.title?.isNotEmpty == true
                                  ? r.title!
                                  : r.filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${r.storageBucket}/${r.storagePath}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () =>
                                Navigator.pop(context, _SendChoice.resource(r)),
                            trailing: const Icon(Icons.chevron_right),
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
      ),
    );
  }
}

// ====== 개별 항목 타일 (리소스 읽기 전용 + 전송 버튼) ======

class _AssignmentTile extends StatefulWidget {
  final String title;
  final List<String> pathSegments;
  final bool done;
  final VoidCallback onToggle;
  final Future<List<ResourceFile>> Function() onFetchResources;
  final Future<void> Function(ResourceFile r) onOpenResource;
  final VoidCallback onSendToTodayLesson;

  const _AssignmentTile({
    required this.title,
    required this.pathSegments,
    required this.done,
    required this.onToggle,
    required this.onFetchResources,
    required this.onOpenResource,
    required this.onSendToTodayLesson,
  });

  @override
  State<_AssignmentTile> createState() => _AssignmentTileState();
}

class _AssignmentTileState extends State<_AssignmentTile> {
  Future<List<ResourceFile>>? _load;
  bool _expanded = false;

  void _toggleExpand() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded && _load == null) {
        _load = widget.onFetchResources();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.pathSegments.isEmpty
        ? null
        : widget.pathSegments.join(' / ');

    return Column(
      children: [
        ListTile(
          leading: Icon(
            widget.done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: widget.done ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(widget.title),
          subtitle: subtitle != null ? Text(subtitle) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '오늘 레슨으로 보내기',
                onPressed: widget.onSendToTodayLesson,
                icon: const Icon(Icons.send),
              ),
              Switch(value: widget.done, onChanged: (_) => widget.onToggle()),
              IconButton(
                tooltip: _expanded ? '리소스 닫기' : '리소스 보기',
                onPressed: _toggleExpand,
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              ),
            ],
          ),
          onTap: _toggleExpand,
        ),
        if (_expanded)
          FutureBuilder<List<ResourceFile>>(
            future: _load,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('리소스 로드 실패\n${snap.error}'),
                  ),
                );
              }
              final items = snap.data ?? const <ResourceFile>[];
              if (items.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('이 항목에 연결된 리소스가 없습니다.'),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                child: Column(
                  children: [
                    for (final r in items)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.description),
                        title: Text(
                          r.title?.isNotEmpty == true ? r.title! : r.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${r.storageBucket}/${r.storagePath}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: '열기',
                          onPressed: () => widget.onOpenResource(r),
                          icon: const Icon(Icons.open_in_new),
                        ),
                        onTap: () => widget.onOpenResource(r),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}
