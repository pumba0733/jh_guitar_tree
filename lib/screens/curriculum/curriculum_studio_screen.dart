// lib/screens/curriculum/curriculum_studio_screen.dart
// v1.74.4 | 리소스 다이얼로그 개선 + 파일명 변경 버튼/동작 추가
// - 목록 기본 정렬: 파일명 오름차순(ABC, 가나다)
// - 파일명 검색(경로 제외) 추가
// - '파일명 변경' 버튼 추가: ResourceService.renameResourceFilename(...) 호출

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../models/curriculum.dart';
import '../../models/resource.dart';
import '../../services/curriculum_service.dart';
import '../../services/resource_service.dart';
import '../../services/file_service.dart';

class CurriculumStudioScreen extends StatefulWidget {
  const CurriculumStudioScreen({super.key});
  @override
  State<CurriculumStudioScreen> createState() => _CurriculumStudioScreenState();
}

class _CurriculumStudioScreenState extends State<CurriculumStudioScreen> {
  final _svc = CurriculumService();
  final _resSvc = ResourceService();
  late Future<List<Map<String, dynamic>>> _load;

  @override
  void initState() {
    super.initState();
    _load = _svc.listNodes();
  }

  Future<void> _refresh() async {
    final future = _svc.listNodes();
    if (!mounted) return;
    setState(() {
      _load = future;
    });
    await future;
  }

  Future<void> _addNode({String? parentId, required String type}) async {
    final title = await _promptText(
      context,
      '새 ${type == 'file' ? '파일' : '카테고리'} 제목',
    );
    if (title == null) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    try {
      await _svc.createNode(parentId: parentId, type: type, title: trimmed);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('생성 실패: $e')));
    }
  }

  Future<void> _editNode(CurriculumNode n) async {
    final title = await _promptText(context, '제목 수정', initial: n.title);
    if (title == null) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    await _svc.updateNode(id: n.id, title: trimmed);
    await _refresh();
  }

  Future<void> _deleteNode(CurriculumNode n) async {
    final ok = await _confirm(
      context,
      title: '삭제',
      message: '하위 항목도 함께 삭제될 수 있습니다. 진행할까요?',
      danger: true,
    );
    if (!ok) return;
    await _svc.deleteNode(n.id);
    await _refresh();
  }

  Future<void> _openUrl(String url) async {
    var u = url.trim();
    if (!u.contains('://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('잘못된 URL 형식입니다.')));
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('URL을 열 수 없습니다: $u')));
    }
  }

  Future<void> _openResourceManager(CurriculumNode n) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ResourceManagerSheet(node: n, svc: _resSvc),
    );
  }

  Future<void> _openSiblingReorderDialog({
    required String? parentId,
    required List<CurriculumNode> siblings,
  }) async {
    if (!mounted) return;
    final result = await showDialog<List<CurriculumNode>>(
      context: context,
      builder: (_) => _SiblingReorderDialog(siblings: siblings),
    );
    if (result == null) return;
    for (var i = 0; i < result.length; i++) {
      final n = result[i];
      await _svc.updateNode(id: n.id, order: i);
    }
    await _refresh();
  }

  Future<void> _openMoveDialog({
    required CurriculumNode target,
    required List<CurriculumNode> allNodes,
  }) async {
    final byId = {for (final n in allNodes) n.id: n};

    bool isDescendant(String? candidateId, String nodeId) {
      var cursor = candidateId;
      while (cursor != null) {
        if (cursor == nodeId) return true;
        cursor = byId[cursor]?.parentId;
      }
      return false;
    }

    final allowed = <_MoveCandidate>[];
    if (target.type == 'category') {
      allowed.add(_MoveCandidate(id: null, pathText: '루트(최상위)', isRoot: true));
    }
    for (final n in allNodes) {
      if (n.type != 'category') continue;
      if (n.id == target.id) continue;
      if (isDescendant(n.id, target.id)) continue;
      final path = _buildPathText(n, byId);
      allowed.add(_MoveCandidate(id: n.id, pathText: path));
    }

    if (allowed.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이동 가능한 위치가 없습니다.')));
      return;
    }

    final dest = await showDialog<_MoveCandidate>(
      context: context,
      builder: (_) => _MoveNodeDialog(target: target, candidates: allowed),
    );
    if (dest == null) return;

    await _moveNodeTo(target: target, newParentId: dest.id, allNodes: allNodes);
  }

  Future<void> _moveNodeTo({
    required CurriculumNode target,
    required String? newParentId,
    required List<CurriculumNode> allNodes,
  }) async {
    try {
      if (target.type == 'file' && newParentId == null) {
        throw '파일 노드는 루트(최상위)로 이동할 수 없습니다.';
      }
      final siblings = allNodes.where((x) => x.parentId == newParentId).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      final newOrder = siblings.isEmpty ? 0 : (siblings.last.order + 1);

      await _svc.moveNode(
        id: target.id,
        newParentId: newParentId,
        newOrder: newOrder,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('이동 완료: "${target.title}"')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('이동 실패: $e')));
    }
  }

  String _buildPathText(CurriculumNode n, Map<String, CurriculumNode> byId) {
    final parts = <String>[];
    var cur = n;
    while (true) {
      parts.add(cur.title);
      final pid = cur.parentId;
      if (pid == null) break;
      final p = byId[pid];
      if (p == null) break;
      cur = p;
    }
    return parts.reversed.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('커리큘럼 스튜디오 (관리자)'),
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

          List<Widget> buildTreeChildren(String? parentId, int depth) {
            final list = byParent[parentId] ?? const <CurriculumNode>[];
            final widgets = <Widget>[];

            for (final n in list) {
              final indent = 16.0 * depth;
              final childrenOfN = byParent[n.id] ?? const <CurriculumNode>[];

              widgets.add(
                Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.only(
                        left: 16 + indent,
                        right: 8,
                      ),
                      leading: Icon(
                        n.type == 'file'
                            ? Icons.insert_drive_file
                            : Icons.folder,
                      ),
                      title: Text(n.title),
                      subtitle: n.fileUrl != null
                          ? InkWell(
                              onTap: () => _openUrl(n.fileUrl!),
                              child: Text(
                                n.fileUrl!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            )
                          : null,
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            tooltip: '형제 정렬',
                            onPressed: () => _openSiblingReorderDialog(
                              parentId: n.parentId,
                              siblings: List<CurriculumNode>.from(
                                byParent[n.parentId] ?? [],
                              ),
                            ),
                            icon: const Icon(Icons.swap_vert),
                          ),
                          IconButton(
                            tooltip: '이동',
                            onPressed: () =>
                                _openMoveDialog(target: n, allNodes: nodes),
                            icon: const Icon(Icons.drive_file_move),
                          ),
                          IconButton(
                            tooltip: '제목',
                            onPressed: () => _editNode(n),
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            tooltip: '삭제',
                            onPressed: () => _deleteNode(n),
                            icon: const Icon(
                              Icons.delete_forever,
                              color: Colors.redAccent,
                            ),
                          ),
                          IconButton(
                            tooltip: '리소스',
                            onPressed: () => _openResourceManager(n),
                            icon: const Icon(Icons.folder_open),
                          ),
                        ],
                      ),
                    ),
                    if (childrenOfN.isNotEmpty)
                      Column(children: buildTreeChildren(n.id, depth + 1)),
                    const Divider(height: 1),
                  ],
                ),
              );
            }
            return widgets;
          }

          Widget buildRootList() {
            final rootList = byParent[null] ?? const <CurriculumNode>[];
            if (rootList.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '커리큘럼이 없습니다.\n우측 하단 + 버튼으로 루트 카테고리를 추가하세요.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView(children: buildTreeChildren(null, 0));
          }

          return Stack(
            children: [
              buildRootList(),
              Positioned(
                right: 16,
                bottom: 16,
                child: FloatingActionButton.extended(
                  heroTag: 'add_root_cat',
                  onPressed: () => _addNode(parentId: null, type: 'category'),
                  icon: const Icon(Icons.create_new_folder),
                  label: const Text('루트 카테고리'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===== 형제 정렬 다이얼로그 =====
class _SiblingReorderDialog extends StatefulWidget {
  final List<CurriculumNode> siblings;
  const _SiblingReorderDialog({required this.siblings});
  @override
  State<_SiblingReorderDialog> createState() => _SiblingReorderDialogState();
}

class _SiblingReorderDialogState extends State<_SiblingReorderDialog> {
  late List<CurriculumNode> _working;
  @override
  void initState() {
    super.initState();
    _working = List<CurriculumNode>.from(widget.siblings)
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('형제 정렬'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: ReorderableListView.builder(
          itemCount: _working.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex -= 1;
              final item = _working.removeAt(oldIndex);
              _working.insert(newIndex, item);
            });
          },
          itemBuilder: (_, i) {
            final n = _working[i];
            return ListTile(
              key: ValueKey(n.id),
              leading: Icon(
                n.type == 'file' ? Icons.insert_drive_file : Icons.folder,
              ),
              title: Text(n.title),
              trailing: const Icon(Icons.drag_handle),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _working),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

// ===== 이동 대상 선택 다이얼로그 =====
class _MoveCandidate {
  final String? id; // null = 루트
  final String pathText;
  final bool isRoot;
  _MoveCandidate({
    required this.id,
    required this.pathText,
    this.isRoot = false,
  });
}

class _MoveNodeDialog extends StatefulWidget {
  final CurriculumNode target;
  final List<_MoveCandidate> candidates;
  const _MoveNodeDialog({required this.target, required this.candidates});
  @override
  State<_MoveNodeDialog> createState() => _MoveNodeDialogState();
}

class _MoveNodeDialogState extends State<_MoveNodeDialog> {
  String _q = '';
  _MoveCandidate? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.candidates.isNotEmpty) {
      _selected = widget.candidates.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.candidates.where((c) {
      if (_q.trim().isEmpty) return true;
      final t = _q.trim().toLowerCase();
      return c.pathText.toLowerCase().contains(t);
    }).toList();

    return AlertDialog(
      title: Text('이동: ${widget.target.title}'),
      content: SizedBox(
        width: 520,
        height: 520,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '카테고리 검색',
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = filtered[i];
                  final sel =
                      _selected?.id == c.id && _selected?.isRoot == c.isRoot;
                  return ListTile(
                    dense: true,
                    title: Text(c.pathText),
                    leading: Icon(
                      c.isRoot ? Icons.home_outlined : Icons.folder,
                    ),
                    trailing: sel
                        ? const Icon(Icons.check, color: Colors.blue)
                        : null,
                    onTap: () => setState(() => _selected = c),
                    onLongPress: () => Navigator.pop(context, c),
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
        FilledButton.icon(
          icon: const Icon(Icons.drive_file_move),
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          label: const Text('이동'),
        ),
      ],
    );
  }
}

// ===== 리소스 관리 시트 =====
class _ResourceManagerSheet extends StatefulWidget {
  final CurriculumNode node;
  final ResourceService svc;
  const _ResourceManagerSheet({required this.node, required this.svc});
  @override
  State<_ResourceManagerSheet> createState() => _ResourceManagerSheetState();
}

class _ResourceManagerSheetState extends State<_ResourceManagerSheet> {
  late Future<List<ResourceFile>> _load;
  bool _dragging = false;
  bool _busy = false; // 업로드/삭제/매핑/이름변경 중 UI 잠금

  // 🔎 파일명 검색 컨트롤러
  final TextEditingController _resSearchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load = widget.svc.listByNode(widget.node.id);
    _resSearchCtl.addListener(() {
      if (mounted) setState(() {}); // 즉시 필터 반영
    });
  }

  @override
  void dispose() {
    _resSearchCtl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final f = widget.svc.listByNode(widget.node.id);
    if (!mounted) return;
    setState(() => _load = f);
    await f;
  }

  Future<void> _uploadByPicker() async {
    if (_busy) return;
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      withReadStream: true,
    );
    if (res == null || res.files.isEmpty) return;

    await _uploadEntries(
      files: res.files
          .map(
            (e) => _Picked(
              name: e.name,
              bytes: e.bytes,
              path: e.path,
              size: e.size,
            ),
          )
          .toList(),
    );
  }

  Future<void> _uploadByDrop(List<XFile> xfiles) async {
    if (_busy) return;
    final entries = <_Picked>[];
    for (final xf in xfiles) {
      entries.add(
        _Picked(
          name: xf.name,
          path: xf.path,
          bytes: null,
          size: await xf.length(),
        ),
      );
    }
    await _uploadEntries(files: entries);
  }

  Future<void> _uploadEntries({required List<_Picked> files}) async {
    if (_busy) return;
    setState(() => _busy = true);
    int okCount = 0;
    for (final f in files) {
      final name = f.name;
      final mime = lookupMimeType(name) ?? 'application/octet-stream';
      try {
        await widget.svc.uploadForNode(
          nodeId: widget.node.id,
          filename: name,
          bytes: f.bytes,
          filePath: f.path,
          mimeType: mime,
          sizeBytes: f.size,
        );
        okCount++;
      } catch (e, st) {
        // ignore: avoid_print
        print('Upload error: $e\n$st');
        final es = '$e';
        final msg =
            (es.contains('403') ||
                es.toLowerCase().contains('row-level security'))
            ? '권한이 없습니다. 관리자/교사 계정으로 로그인했는지 확인해주세요.'
            : es;
        if (!mounted) {
          _busy = false;
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('업로드 실패: $name\n$msg')));
      }
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('업로드 완료: $okCount개')));
    setState(() => _busy = false);
  }

  Future<void> _open(ResourceFile r) async {
    try {
      final url = await widget.svc.signedUrl(r);
      await FileService.instance.openSmart(url: url, name: r.filename);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파일 열기 실패\n$e')));
    }
  }

  Future<void> _delete(ResourceFile r) async {
    if (_busy) return;
    final ok = await _confirm(
      context,
      title: '리소스 삭제',
      message: '스토리지 파일도 함께 삭제됩니다. 진행할까요?',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await widget.svc.delete(r);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ====== (NEW) 리소스 매핑 변경 ======
  Future<void> _remapResource(ResourceFile r) async {
    if (_busy) return;

    final svc = CurriculumService();
    final raw = await svc.listNodes();
    final all = raw
        .map((e) => CurriculumNode.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    final byId = {for (final n in all) n.id: n};

    String pathText(CurriculumNode n) {
      final parts = <String>[];
      var cur = n;
      while (true) {
        parts.add(cur.title);
        if (cur.parentId == null) break;
        final p = byId[cur.parentId];
        if (p == null) break;
        cur = p;
      }
      return parts.reversed.join(' / ');
    }

    final candidates =
        all
            .where((n) => n.type == 'category')
            .map((n) => _MoveCandidate(id: n.id, pathText: pathText(n)))
            .toList()
          ..sort((a, b) => a.pathText.compareTo(b.pathText));

    if (!mounted) return;
    final dest = await showDialog<_MoveCandidate>(
      context: context,
      builder: (_) => _MoveNodeDialog(
        target: CurriculumNode(
          id: r.id,
          parentId: null,
          type: 'file',
          title: r.title ?? r.filename,
          order: 0,
        ),
        candidates: candidates,
      ),
    );
    if (dest == null || dest.id == null) return;

    await _applyRemap(resource: r, newNodeId: dest.id!);
  }

  Future<void> _applyRemap({
    required ResourceFile resource,
    required String newNodeId,
  }) async {
    setState(() => _busy = true);
    try {
      await widget.svc.moveResourceToNode(
        resourceId: resource.id,
        newNodeId: newNodeId,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('이동 완료: ${resource.filename}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('이동 실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ====== (NEW) 파일명 변경 ======
  Future<void> _renameFilename(ResourceFile r) async {
    if (_busy) return;

    final current = r.filename;
    final input = await _promptText(context, '파일명 변경', initial: current);
    if (input == null) return;

    // ✅ 1) 첫 번째 async gap(위 다이얼로그) 후 컨텍스트/상태 사용 전 가드
    if (!mounted) return;

    final newName = input.trim();
    if (newName.isEmpty) return;

    // 확장자 변경 경고(선택): UX 보조 — 저장은 허용
    final oldExt = _extOf(current);
    final newExt = _extOf(newName);
    if (oldExt != newExt && oldExt.isNotEmpty) {
      final ok = await _confirm(
        context,
        title: '확장자 변경 경고',
        message:
            '기존 확장자($oldExt)와 다른 확장자($newExt)가 입력되었습니다.\n그래도 변경할까요?\n(스토리지 파일은 이동/이름변경되지 않으며, DB 파일명만 변경됩니다.)',
        confirmText: '변경',
      );
      // ✅ 2) 두 번째 async gap(확인 다이얼로그) 후 가드
      if (!mounted) return;
      if (!ok) return;
    }

    setState(() => _busy = true);
    try {
      await widget.svc.renameResourceFilename(
        resourceId: r.id,
        newFilename: newName,
        alsoUpdateOriginal: true,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('파일명을 변경했습니다.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파일명 변경 실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }




  String _extOf(String s) {
    final i = s.lastIndexOf('.');
    return (i >= 0 && i < s.length - 1) ? s.substring(i + 1).toLowerCase() : '';
  }

  // 🔎 검색용 정규화: NFC → 소문자 → 구분자 제거
  String _normKo(String s) {
    final nfc = s.isEmpty ? s : unorm.nfc(s);
    return nfc.toLowerCase().replaceAll(
      RegExp(r'[\s\-\_\.\(\)\[\]\{\},/]+'),
      '',
    );
  }

  // 파일명만 기준으로 필터 + 파일명 오름차순 정렬
  List<ResourceFile> _filterAndSort(List<ResourceFile> list) {
    final q = _resSearchCtl.text.trim();
    final needle = _normKo(q);

    bool hit(ResourceFile r) {
      final fname = (r.filename).trim();
      if (fname.isEmpty) return false;
      if (needle.isEmpty) return true;
      return _normKo(fname).contains(needle);
    }

    final filtered = list.where(hit).toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Scaffold(
            appBar: AppBar(
              title: Text('리소스 · ${widget.node.title}'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            body: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (detail) async {
                setState(() => _dragging = false);
                await _uploadByDrop(detail.files);
              },
              child: Column(
                children: [
                  // 업로드 안내
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.all(12),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _dragging
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: const [
                          Icon(Icons.cloud_upload),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '파일을 여기로 드래그하여 업로드하거나, 우측 하단 버튼을 눌러 선택 업로드하세요.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // 🔎 파일명 검색 입력
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _resSearchCtl,
                      decoration: InputDecoration(
                        hintText: '파일명 검색… (경로 제외)',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _resSearchCtl.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () => _resSearchCtl.clear(),
                                tooltip: '검색어 지우기',
                              ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),

                  // 목록
                  Expanded(
                    child: FutureBuilder<List<ResourceFile>>(
                      future: _load,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snap.hasError) {
                          return Center(child: Text('로드 실패\n${snap.error}'));
                        }
                        final items = snap.data ?? const <ResourceFile>[];
                        if (items.isEmpty) {
                          return const Center(
                            child: Text(
                              '리소스가 없습니다. 파일을 드래그하거나, 우측 하단 업로드 버튼을 눌러 추가하세요.',
                            ),
                          );
                        }

                        final list = _filterAndSort(items);

                        return ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = list[i];
                            final subtitle =
                                '${r.storageBucket}/${r.storagePath}';
                            return ListTile(
                              leading: const Icon(Icons.description),
                              title: Text(
                                (r.title?.isNotEmpty ?? false)
                                    ? r.title!
                                    : r.filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _open(r),
                              trailing: Wrap(
                                spacing: 4,
                                children: [
                                  IconButton(
                                    tooltip: '열기',
                                    onPressed: _busy ? null : () => _open(r),
                                    icon: const Icon(Icons.open_in_new),
                                  ),
                                  IconButton(
                                    tooltip: '매핑 변경',
                                    onPressed: _busy
                                        ? null
                                        : () => _remapResource(r),
                                    icon: const Icon(
                                      Icons.drive_file_move_outline,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '파일명 변경',
                                    onPressed: _busy
                                        ? null
                                        : () => _renameFilename(r),
                                    icon: const Icon(
                                      Icons.drive_file_rename_outline,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '삭제',
                                    onPressed: _busy ? null : () => _delete(r),
                                    icon: const Icon(
                                      Icons.delete_forever,
                                      color: Colors.redAccent,
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
            floatingActionButton: FloatingActionButton.extended(
              onPressed: _busy ? null : _uploadByPicker,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_busy ? '업로드 중...' : '업로드'),
            ),
          ),
        ),
      ),
    );
  }
}

class _Picked {
  final String name;
  final Uint8List? bytes;
  final String? path;
  final int size;
  _Picked({required this.name, this.bytes, this.path, required this.size});
}

// ===== 공용 다이얼로그 =====
Future<String?> _promptText(
  BuildContext context,
  String title, {
  String? initial,
}) async {
  final c = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '진행',
  String cancelText = '취소',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelText),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}
