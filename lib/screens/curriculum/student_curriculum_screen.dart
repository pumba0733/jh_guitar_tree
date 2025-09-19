// lib/screens/curriculum/student_curriculum_screen.dart
// v1.58.0 | B안 정합 보강
// - 초기 진입 시 ensureTeacherLink() 호출(교사 세션-DB 연결 보강)
// - 초기 fetch → 이후 구독 패턴은 이 화면에서 fetch만 담당(구독은 상위에서 선택적으로)
// - 복습 섹션/배정 섹션 로딩·리트라이 UX 미세개선

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/curriculum_service.dart';
import '../../services/progress_service.dart';
import '../../services/resource_service.dart';
import '../../services/lesson_links_service.dart';
import '../../services/file_service.dart';
import '../../services/lesson_service.dart';

import '../../models/curriculum.dart';
import '../../models/resource.dart';

// 내부용: 복습 리소스 그룹(레슨별)
class _ReviewedGroup {
  final String lessonId;
  final String dateStr; // YYYY-MM-DD
  final List<ResourceFile> resources;
  _ReviewedGroup({
    required this.lessonId,
    required this.dateStr,
    required this.resources,
  });
}

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
  final _lessonSvc = LessonService();

  Future<
    ({
      List<CurriculumAssignment> assigns,
      Map<String, CurriculumNode> nodeMap,
      Map<String, bool> doneMap,
    })
  >?
  _load;

  Future<List<_ReviewedGroup>>? _reviewedLoad;

    @override
  void initState() {
    super.initState();
    AuthService().ensureTeacherLink();

    // ensureStudentBinding 완료 후에 fetch 시작
    Future.microtask(() async {
      try {
        await _svc.ensureStudentBinding(widget.studentId);
        // 아주 짧은 딜레이로 RLS 전파 대기
        await Future.delayed(const Duration(milliseconds: 80));
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _load = _fetch();
        _reviewedLoad = _fetchReviewed();
      });
    });
  }


  Future<
    ({
      List<CurriculumAssignment> assigns,
      Map<String, CurriculumNode> nodeMap,
      Map<String, bool> doneMap,
    })
  >
  _fetch() async {
    // 노드 트리
    final nodesRaw = await _svc.listNodes();
    final nodes = nodesRaw
        .map((e) => CurriculumNode.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    final nodeMap = {for (final n in nodes) n.id: n};

    // 배정
    final assignsRaw = await _svc.listAssignmentsByStudent(widget.studentId);
    final assigns = assignsRaw
        .map((e) => CurriculumAssignment.fromMap(Map<String, dynamic>.from(e)))
        .toList();

    // 진도
    final doneMap = await _progress.mapByStudent(widget.studentId);
    return (assigns: assigns, nodeMap: nodeMap, doneMap: doneMap);
  }

  // 지난 수업 리소스 수집
  Future<List<_ReviewedGroup>> _fetchReviewed({int maxLessons = 20}) async {
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    final todayStr = d0.toIso8601String().split('T').first;

    final lessons = await _lessonSvc.listByStudent(
      widget.studentId,
      limit: maxLessons,
    );

    final groups = <_ReviewedGroup>[];
    for (final raw in lessons) {
      final row = Map<String, dynamic>.from(raw);
      final id = (row['id'] ?? '').toString();
      final dateStr = (row['date'] ?? '').toString();
      if (id.isEmpty || dateStr.isEmpty) continue;
      if (dateStr == todayStr) continue;

      final links = await _links.listByLesson(id);
      if (links.isEmpty) continue;

      final seen = <String>{};
      final resList = <ResourceFile>[];
      for (final m in links) {
        final mm = Map<String, dynamic>.from(m);
        if ((mm['kind'] ?? '') != 'resource') continue;
        final bucket = (mm['resource_bucket'] ?? ResourceService.bucket)
            .toString();
        final path = (mm['resource_path'] ?? '').toString();
        if (path.isEmpty) continue;

        final key = '$bucket::$path';
        if (seen.contains(key)) continue;
        seen.add(key);

        resList.add(
          ResourceFile.fromMap({
            'id': mm['id']?.toString() ?? '',
            'curriculum_node_id': mm['curriculum_node_id'],
            'title': (mm['resource_title'] ?? '').toString(),
            'filename': (mm['resource_filename'] ?? 'file').toString(),
            'mime_type': null,
            'size_bytes': null,
            'storage_bucket': bucket,
            'storage_path': path,
            'created_at': mm['created_at'],
          }),
        );
      }

      if (resList.isNotEmpty) {
        groups.add(
          _ReviewedGroup(lessonId: id, dateStr: dateStr, resources: resList),
        );
      }
    }

    groups.sort((a, b) => b.dateStr.compareTo(a.dateStr));
    return groups;
  }

  Future<void> _refresh() async {
    final f1 = _fetch();
    final f2 = _fetchReviewed();
    if (!mounted) return;
    setState(() {
      _load = f1;
      _reviewedLoad = f2;
    });
    await Future.wait([f1, f2]);
  }

  Future<void> _toggle(String nodeId) async {
    final ok = await _progress.toggle(
      studentId: widget.studentId,
      nodeId: nodeId,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('진도 테이블이 준비되지 않았습니다. (SQL 적용 필요)')),
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
    } catch (_) {
      ok = false;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '오늘 레슨으로 보냈어요.' : '전송 실패 또는 미구현(SQL 보강 필요)')),
    );
  }

  // ===== UI =====

  Widget _buildReviewedSection() {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        title: const Text('📚 지난 수업에서 다룬 리소스'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        trailing: IconButton(
          tooltip: '새로고침',
          icon: const Icon(Icons.refresh),
          onPressed: _refresh,
        ),
        children: [
                    if (_reviewedLoad == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else
            FutureBuilder<List<_ReviewedGroup>>(
              future: _reviewedLoad,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }

              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('복습 리소스를 불러오지 못했어요.\n${snap.error}'),
                );
              }
              final groups = snap.data ?? const <_ReviewedGroup>[];
              if (groups.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('아직 지난 수업에서 다룬 리소스가 없어요.'),
                );
              }

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: groups.length,
                separatorBuilder: (_, __) => const Divider(height: 16),
                itemBuilder: (_, gi) {
                  final g = groups[gi];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event_note),
                        title: Text(g.dateStr),
                        subtitle: Text('리소스 ${g.resources.length}개'),
                      ),
                      ...g.resources.map(
                        (r) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.insert_drive_file),
                          title: Text(
                            (r.title?.isNotEmpty == true
                                    ? r.title!
                                    : r.filename)
                                .trim(),
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
                            icon: const Icon(Icons.open_in_new),
                            onPressed: () => _openResource(r),
                          ),
                          onTap: () => _openResource(r),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
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
            body: _load == null
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder<
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

              // 배정이 없더라도 복습 섹션은 항상 표시
              if (data.assigns.isEmpty) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text(
                          '배정된 커리큘럼이 없습니다.\n강사에게 배정을 요청하세요.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      _buildReviewedSection(),
                    ],
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

                  // 복습 섹션
                  _buildReviewedSection(),

                  // 배정 목록
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

// ====== 개별 항목 타일 ======

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
