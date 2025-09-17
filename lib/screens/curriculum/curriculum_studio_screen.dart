// lib/screens/curriculum/curriculum_studio_screen.dart
// v1.46.3 | 커리큘럼 스튜디오 (루트 file 생성 버튼 제거/문구 수정)
// - 리소스 업로드/열기/삭제, 형제 정렬, 하위 category/file 추가 그대로 유지
// - 서비스 가드/DB 제약과 UI 정책 일치

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';

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
    setState(() => _load = future);
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

  Future<void> _editFileUrl(CurriculumNode n) async {
    final url = await _promptText(
      context,
      '파일/링크 URL',
      initial: n.fileUrl ?? '',
    );
    if (url == null) return;

    final trimmed = url.trim();
    await _svc.updateNode(id: n.id, fileUrl: trimmed.isEmpty ? null : trimmed);
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

  Future<void> _moveOrder(CurriculumNode n, int delta) async {
    final newOrder = n.order + delta;
    await _svc.updateNode(id: n.id, order: newOrder);
    await _refresh();
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
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
      ).showSnackBar(SnackBar(content: Text('URL을 열 수 없습니다: $url')));
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
                            tooltip: '위로',
                            onPressed: () => _moveOrder(n, -1),
                            icon: const Icon(Icons.arrow_upward, size: 20),
                          ),
                          IconButton(
                            tooltip: '아래로',
                            onPressed: () => _moveOrder(n, 1),
                            icon: const Icon(Icons.arrow_downward, size: 20),
                          ),
                          IconButton(
                            tooltip: '리소스 관리',
                            onPressed: () => _openResourceManager(n),
                            icon: const Icon(Icons.attach_file),
                          ),
                          if (n.type == 'file')
                            IconButton(
                              tooltip: '링크 편집(호환)',
                              onPressed: () => _editFileUrl(n),
                              icon: const Icon(Icons.link),
                            ),
                          IconButton(
                            tooltip: '제목',
                            onPressed: () => _editNode(n),
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            tooltip: '하위 카테고리',
                            onPressed: () =>
                                _addNode(parentId: n.id, type: 'category'),
                            icon: const Icon(Icons.create_new_folder),
                          ),
                          IconButton(
                            tooltip: '하위 파일',
                            onPressed: () =>
                                _addNode(parentId: n.id, type: 'file'),
                            icon: const Icon(Icons.note_add),
                          ),
                          IconButton(
                            tooltip: '삭제',
                            onPressed: () => _deleteNode(n),
                            icon: const Icon(
                              Icons.delete_forever,
                              color: Colors.redAccent,
                            ),
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

  @override
  void initState() {
    super.initState();
    _load = widget.svc.listByNode(widget.node.id);
  }

  Future<void> _refresh() async {
    final f = widget.svc.listByNode(widget.node.id);
    if (!mounted) return;
    setState(() => _load = f);
    await f;
  }

  Future<void> _uploadByPicker() async {
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
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('업로드 실패: $name\n$e')));
      }
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('업로드 완료: $okCount개')));
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
    final ok = await _confirm(
      context,
      title: '리소스 삭제',
      message: '스토리지 파일도 함께 삭제됩니다. 진행할까요?',
      danger: true,
    );
    if (!ok) return;
    await widget.svc.delete(r);
    await _refresh();
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
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
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
                        return ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = items[i];
                            final subtitle =
                                '${r.storageBucket}/${r.storagePath}';
                            return ListTile(
                              leading: const Icon(Icons.description),
                              title: Text(
                                (r.title?.isNotEmpty ?? false)
                                    ? r.title!
                                    : r.filename,
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
                                    onPressed: () => _open(r),
                                    icon: const Icon(Icons.open_in_new),
                                  ),
                                  IconButton(
                                    tooltip: '삭제',
                                    onPressed: () => _delete(r),
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
              onPressed: _uploadByPicker,
              icon: const Icon(Icons.upload_file),
              label: const Text('업로드'),
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
