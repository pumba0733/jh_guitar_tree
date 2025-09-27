// lib/screens/curriculum/student_curriculum_screen.dart
// v1.71.2-lintfix | 지난 수업 리소스: 전역 중복 제거 + 최신순 보장
// - 로컬 함수 언더스코어 제거 유지 (parseDate, resKey, attKey)
// - if(!mounted) 단일문 → 블록으로 감싸 린트 해결 (curly_braces_in_flow_control_structures)

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
import '../../services/xsc_sync_service.dart';

// 표시 공통 모델
enum _ReviewedItemKind { linkResource, attachment }

class _ReviewedItem {
  final _ReviewedItemKind kind;
  final String label; // 파일/리소스/노드 표기
  final String sub; // 경로/출처
  final Future<void> Function() onOpen;
  final Map<String, dynamic>? src; // v1.70: 오늘 레슨에 담기용 원본 map

  _ReviewedItem({
    required this.kind,
    required this.label,
    required this.sub,
    required this.onOpen,
    this.src,
  });
}

// 레슨별 그룹
class _ReviewedGroup {
  final String lessonId;
  final String dateStr; // YYYY-MM-DD
  final List<_ReviewedItem> items;
  _ReviewedGroup({
    required this.lessonId,
    required this.dateStr,
    required this.items,
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

    Future.microtask(() async {
      try {
        await _svc.ensureStudentBinding(widget.studentId);
        await Future.delayed(const Duration(milliseconds: 80)); // RLS 전파 대기
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

  // 지난 수업 리소스 수집 — 오늘 레슨도 포함
  // ✅ 전역 중복 제거(가장 최신만 보이도록), 최신 레슨부터 정렬
  Future<List<_ReviewedGroup>> _fetchReviewed({int maxLessons = 20}) async {
    final lessons = await _lessonSvc.listByStudent(
      widget.studentId,
      limit: maxLessons,
    );

    // 날짜 파싱 유틸
    DateTime parseDate(dynamic v) {
      if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
      if (v is DateTime) return v;
      final s = v.toString();
      // YYYY-MM-DD... 형태 우선 처리
      final normalized = s.replaceAll('.', '-').replaceAll('/', '-');
      return DateTime.tryParse(normalized) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }

    // 1) 최신순 정렬 보장
    final sorted = lessons.map((e) => Map<String, dynamic>.from(e)).toList()
      ..sort((a, b) => parseDate(b['date']).compareTo(parseDate(a['date'])));

    // 2) 전역 중복 제거 키 셋 (레슨 전체 범위)
    // 리소스: bucket::path[::filename] (filename 까지 포함해 더 보수적으로)
    final globalSeenRes = <String>{};
    // 첨부: localPath / url / path 중 우선순위로 구성
    final globalSeenAtt = <String>{};

    String resKey(Map<String, dynamic> mm) {
      final bucket = (mm['resource_bucket'] ?? ResourceService.bucket)
          .toString()
          .trim();
      final path = (mm['resource_path'] ?? '').toString().trim();
      final fname = (mm['resource_filename'] ?? '').toString().trim();
      return '$bucket::$path::${fname.isEmpty ? '(nofile)' : fname}';
    }

    String attKey(Map<String, dynamic> m) {
      final localPath = (m['localPath'] ?? '').toString().trim();
      final url = (m['url'] ?? '').toString().trim();
      final path = (m['path'] ?? '').toString().trim();
      if (localPath.isNotEmpty) return 'local::$localPath';
      if (url.isNotEmpty) return 'url::$url';
      return 'path::$path';
    }

    final groups = <_ReviewedGroup>[];

    for (final row in sorted) {
      final id = (row['id'] ?? '').toString();
      final dateStr = (row['date'] ?? '').toString();
      if (id.isEmpty || dateStr.isEmpty) continue;

      final items = <_ReviewedItem>[];
      final seen = <String>{}; // 레슨 내부 중복 방지(보조)

      // 1) lesson_links (resource)
      final links = await _links.listByLesson(id);
      for (final m in links) {
        final mm = Map<String, dynamic>.from(m);
        final bucket = (mm['resource_bucket'] ?? ResourceService.bucket)
            .toString();
        final path = (mm['resource_path'] ?? '').toString();
        if (path.isEmpty) continue;

        final gkey = resKey(mm);
        if (!globalSeenRes.add(gkey)) continue; // ✅ 전역 중복 제거
        final lkey = '$bucket::$path';
        if (!seen.add(lkey)) continue; // 레슨 내부 보조 중복 제거

        final filename = (mm['resource_filename'] ?? 'resource').toString();
        final title = (mm['resource_title'] ?? '').toString();
        final label = (title.isNotEmpty ? title : filename).trim();

        items.add(
          _ReviewedItem(
            kind: _ReviewedItemKind.linkResource,
            label: label.isEmpty ? '리소스' : label,
            sub: '$bucket/$path',
            onOpen: () => XscSyncService().openFromLessonLinkMap(
              link: mm,
              studentId: widget.studentId,
            ),
            src: mm, // v1.70 유지
          ),
        );
      }

      // 2) lessons.attachments
      final atts = row['attachments'];
      if (atts is List) {
        for (final a in atts) {
          final map = (a is Map)
              ? Map<String, dynamic>.from(a)
              : <String, dynamic>{
                  'url': a.toString(),
                  'path': a.toString(),
                  'name': a.toString().split('/').last,
                };

          final localPath = (map['localPath'] ?? '').toString();
          final url = (map['url'] ?? '').toString();
          final path = (map['path'] ?? '').toString();
          final name = (map['name'] ?? path.split('/').last).toString();

          final gkey = attKey(map);
          if (!globalSeenAtt.add(gkey)) continue; // ✅ 전역 중복 제거

          final lkey = localPath.isNotEmpty ? 'local::$localPath' : 'url::$url';
          if (!seen.add(lkey)) continue; // 레슨 내부 보조 중복 제거

          items.add(
            _ReviewedItem(
              kind: _ReviewedItemKind.attachment,
              label: name.isEmpty ? '첨부' : name,
              sub: localPath.isNotEmpty
                  ? localPath
                  : (url.isNotEmpty ? url : path),
              onOpen: () async {
                // ✅ 첨부도 XSC 루틴으로
                await LessonLinksService().openFromAttachment(
                  LessonAttachmentItem(
                    lessonId: id, // 해당 레슨 id
                    type: (map['type'] ?? 'url').toString(),
                    createdAt: DateTime.now(),
                    localPath: localPath.isNotEmpty ? localPath : null,
                    url: url.isNotEmpty ? url : null,
                    path: path.isNotEmpty ? path : null,
                    originalFilename: (map['name'] ?? '').toString().isNotEmpty
                        ? map['name'].toString()
                        : null,
                    mediaName: (map['mediaName'] ?? '').toString().isNotEmpty
                        ? map['mediaName'].toString()
                        : null,
                    xscStoragePath: null,
                    xscUpdatedAt: null,
                  ),
                  studentId: widget.studentId,
                );
              },
              src: map,
            ),
          );

        }
      }

      // 이 레슨에서 보여줄 항목이 남아있을 때만 그룹 추가
      if (items.isNotEmpty) {
        groups.add(
          _ReviewedGroup(lessonId: id, dateStr: dateStr, items: items),
        );
      }
    }

    // 상단 최신순 유지(이미 최신→과거 순으로 만들었지만 안전하게 한 번 더)
    groups.sort((a, b) => b.dateStr.compareTo(a.dateStr));
    return groups;
  }

  Future<void> _refresh() async {
    final f1 = _fetch();
    final f2 = _fetchReviewed();
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
      final url = await _resSvc.signedUrl(r);
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

  // v1.70: 개별 담기 공통 스낵바
  void _showAddResultSnack(AddResult r) {
    final msg = '✅ ${r.added}개 추가됨 (중복 ${r.duplicated}, 실패 ${r.failed})';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

                return ListView(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
                  children: [
                    if (data.assigns.isEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text(
                          '배정된 커리큘럼이 없습니다.\n강사에게 배정을 요청하세요.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ] else ...[
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
                              '완료 ${data.doneMap.values.where((v) => v).length} / ${data.assigns.length}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const Spacer(),
                            Text(
                              data.doneMap.values.where((v) => v).length ==
                                      data.assigns.length
                                  ? '완료됨'
                                  : '${(((data.doneMap.values.where((v) => v).length / data.assigns.length) * 100)).toStringAsFixed(0)}%',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ===== 📚 지난 수업 섹션 =====
                    Card(
                      elevation: 0,
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ExpansionTile(
                        title: const Text('📚 지난 수업에서 다룬 리소스'),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          12,
                          0,
                          12,
                          12,
                        ),
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
                                if (snap.connectionState !=
                                    ConnectionState.done) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: LinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  );
                                }
                                if (snap.hasError) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Text(
                                      '복습 리소스를 불러오지 못했어요.\n${snap.error}',
                                    ),
                                  );
                                }
                                final groups = snap.data ?? [];
                                if (groups.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: Text('아직 지난 수업에서 다룬 리소스가 없어요.'),
                                  );
                                }
                                return Column(
                                  children: groups.map((g) {
                                    final resItems = g.items
                                        .where(
                                          (it) =>
                                              it.kind ==
                                              _ReviewedItemKind.linkResource,
                                        )
                                        .toList();
                                    final attItems = g.items
                                        .where(
                                          (it) =>
                                              it.kind ==
                                              _ReviewedItemKind.attachment,
                                        )
                                        .toList();
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (resItems.isNotEmpty) ...[
                                          const Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              12,
                                              4,
                                              12,
                                              4,
                                            ),
                                            child: Text(
                                              '리소스',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          ...resItems.map(
                                            (it) => ListTile(
                                              dense: true,
                                              leading: const Icon(
                                                Icons.insert_drive_file,
                                              ),
                                              title: Text(
                                                it.label,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: Text(
                                                it.sub,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              trailing: Wrap(
                                                spacing: 8,
                                                children: [
                                                  OutlinedButton.icon(
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                      '오늘 레슨에 담기',
                                                    ),
                                                    onPressed: it.src == null
                                                        ? null
                                                        : () async {
                                                            final r = await _links
                                                                .addResourceLinkMapToToday(
                                                                  studentId: widget
                                                                      .studentId,
                                                                  linkRow:
                                                                      it.src!,
                                                                );
                                                            if (!mounted) {
                                                              return;
                                                            }
                                                            _showAddResultSnack(
                                                              r,
                                                            );
                                                          },
                                                  ),
                                                  IconButton(
                                                    tooltip: '열기',
                                                    icon: const Icon(
                                                      Icons.open_in_new,
                                                    ),
                                                    onPressed: it.onOpen,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (attItems.isNotEmpty) ...[
                                          const Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              12,
                                              8,
                                              12,
                                              4,
                                            ),
                                            child: Text(
                                              '첨부',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          ...attItems.map(
                                            (it) => ListTile(
                                              dense: true,
                                              leading: const Icon(
                                                Icons.attachment,
                                              ),
                                              title: Text(
                                                it.label,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: Text(
                                                it.sub,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              trailing: Wrap(
                                                spacing: 8,
                                                children: [
                                                  OutlinedButton.icon(
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                      '오늘 레슨에 담기',
                                                    ),
                                                    onPressed: it.src == null
                                                        ? null
                                                        : () async {
                                                            final r = await _links
                                                                .addAttachmentMapToToday(
                                                                  studentId: widget
                                                                      .studentId,
                                                                  attachment:
                                                                      it.src!,
                                                                );
                                                            if (!mounted) {
                                                              return;
                                                            }
                                                            _showAddResultSnack(
                                                              r,
                                                            );
                                                          },
                                                  ),
                                                  IconButton(
                                                    tooltip: '열기',
                                                    icon: const Icon(
                                                      Icons.open_in_new,
                                                    ),
                                                    onPressed: it.onOpen,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                        const Divider(),
                                      ],
                                    );
                                  }).toList(),
                                );
                              },
                            ),
                        ],
                      ),
                    ),

                    // ===== 배정 목록 =====
                    for (final a in data.assigns)
                      _AssignmentTile(
                        title:
                            data.nodeMap[a.curriculumNodeId]?.title ??
                            '(삭제된 항목)',
                        pathSegments: a.path ?? const [],
                        done: data.doneMap[a.curriculumNodeId] ?? false,
                        onToggle: () => _toggle(a.curriculumNodeId),
                        onFetchResources: () =>
                            _resSvc.listByNode(a.curriculumNodeId),
                        onOpenResource: _openResource,
                        onSendToTodayLesson: () => _sendToTodayLesson(
                          nodeId: a.curriculumNodeId,
                          nodeTitle:
                              data.nodeMap[a.curriculumNodeId]?.title ??
                              '(삭제된 항목)',
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

// ====== 전송 선택 바텀시트 (기존 유지) ======

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
                        separatorBuilder: (_, _) => const Divider(height: 1),
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

// ====== 개별 항목 타일 (기존 유지) ======

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
