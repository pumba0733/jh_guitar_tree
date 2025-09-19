// v1.38.11 | PGRST116(406) 회피: maybeSingle() 제거 → 리스트 기반 체크
// - insert/update/delete 뒤 .select('id') 결과를 List로 받고 빈 배열 여부로 성공 판정
// - 나머지 UX/로직/가드(mounted, _busy) 동일

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/keyword_service.dart';
import '../../supabase/supabase_tables.dart';

class ManageKeywordsScreen extends StatefulWidget {
  const ManageKeywordsScreen({super.key});

  @override
  State<ManageKeywordsScreen> createState() => _ManageKeywordsScreenState();
}

class _ManageKeywordsScreenState extends State<ManageKeywordsScreen> {
  final KeywordService _keyword = KeywordService();
  final SupabaseClient _client = Supabase.instance.client;

  bool _adminChecked = false;
  bool _isAdmin = false;

  String? _selectedCategory;
  List<String> _allCategories = [];
  List<String> _filteredCategories = [];

  final TextEditingController _catFilterCtl = TextEditingController();
  final TextEditingController _catQuickAddCtl = TextEditingController();

  List<KeywordItem> _items = [];
  bool _loading = true;
  bool _busy = false;

  // ---------- 안전 헬퍼 ----------
  void snack(String message) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(SnackBar(content: Text(message)));
  }

  void popIfMounted() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureAdmin();
    });
  }

  // ----- 관리자 체크 -----
  Future<void> _ensureAdmin() async {
    try {
      const appMode = String.fromEnvironment('APP_MODE', defaultValue: 'prod');
      if (appMode != 'prod') {
        if (!mounted) return;
        setState(() {
          _isAdmin = true;
          _adminChecked = true;
        });
        await _loadCategories();
        return;
      }

      Future<bool> checkAdmin() async {
        final d = await _client.rpc('is_current_user_admin');
        if (d is bool) return d;
        if (d is num) return d != 0;
        if (d is Map) {
          final v = d['is_current_user_admin'] ?? d['ok'];
          if (v is bool) return v;
          if (v is num) return v != 0;
        }
        return false;
      }

      var ok = await checkAdmin();

      if (!ok) {
        final email = _client.auth.currentUser?.email;
        if (email != null && email.trim().isNotEmpty) {
          try {
            await _client.rpc(
              'sync_auth_user_id_by_email',
              params: {'p_email': email},
            );
            ok = await checkAdmin();
          } catch (_) {
            /* ignore */
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _isAdmin = ok;
        _adminChecked = true;
      });
      if (_isAdmin) await _loadCategories();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _adminChecked = true;
        _isAdmin = false;
      });
      snack('관리자 확인 중 오류: $e');
    }
  }

  // ----- 데이터 로드 -----
  Future<void> _loadCategories({bool force = false}) async {
    if (!mounted) return;
    setState(() => _loading = true);

    final cats = await _keyword.fetchCategories(force: force);

    if (!mounted) return;
    setState(() {
      _allCategories = cats;
      _applyCategoryFilter();
      if (_selectedCategory != null && cats.contains(_selectedCategory)) {
        // keep
      } else {
        _selectedCategory = cats.isNotEmpty ? cats.first : null;
      }
    });

    if (_selectedCategory != null) {
      await _loadItems(_selectedCategory!, force: force);
    } else {
      if (!mounted) return;
      setState(() => _items = []);
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _applyCategoryFilter() {
    final q = _catFilterCtl.text.trim().toLowerCase();
    if (q.isEmpty) {
      _filteredCategories = List.of(_allCategories);
    } else {
      _filteredCategories = _allCategories
          .where((c) => c.toLowerCase().contains(q))
          .toList();
    }
  }

  Future<void> _loadItems(String category, {bool force = false}) async {
    if (!mounted) return;
    final list = await _keyword.fetchItemsByCategory(category, force: force);
    if (!mounted) return;
    setState(() {
      _selectedCategory = category;
      _items = list;
    });
  }

  // ----- 공통 가드 -----
  bool get _canAct => mounted && !_busy;

  Future<T?> _runGuard<T>(Future<T> Function() task) async {
    if (!_canAct) return null;
    setState(() => _busy = true);
    try {
      return await task();
    } catch (e) {
      snack('처리 중 오류가 발생했습니다: $e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ----- 카테고리 CRUD -----
  Future<void> _addCategory({String? preset}) async {
    if (!_canAct) return;

    final ctl = TextEditingController(text: preset ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 카테고리 추가'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '카테고리 이름'),
          onSubmitted: (_) => Navigator.pop(ctx, ctl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final n = name.trim();
    if (n.isEmpty) return;

    if (_allCategories
        .map((e) => e.toLowerCase().trim())
        .contains(n.toLowerCase())) {
      snack('이미 존재하는 카테고리입니다.');
      return;
    }

    await _runGuard(() async {
      final rows =
          await _client
                  .from(SupabaseTables.feedbackKeywords)
                  .insert({'category': n, 'items': []})
                  .select('id')
              as List;

      if (rows.isEmpty) {
        snack('카테고리 추가에 실패했습니다. 권한을 확인하세요.');
        return;
      }

      _keyword.invalidateCache();
      await _loadCategories(force: true);
      snack('카테고리 "$n" 추가됨');
    });
  }

  Future<void> _deleteCategory(String category) async {
    if (!_canAct) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('카테고리 삭제'),
        content: Text('카테고리 "$category"와 그 안의 모든 키워드를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _runGuard(() async {
      final List rows =
          await _client
                  .from(SupabaseTables.feedbackKeywords)
                  .delete()
                  .eq('category', category)
                  .select('id')
              as List;

      if (rows.isEmpty) {
        snack('삭제 대상이 없거나 권한이 없습니다.');
        return;
      }

      _keyword.invalidateCache();
      if (_selectedCategory == category) _selectedCategory = null;
      await _loadCategories(force: true);
      snack('카테고리 "$category" 삭제 완료');
    });
  }

  Future<void> _renameCategory(String oldName) async {
    if (!_canAct) return;

    final ctl = TextEditingController(text: oldName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('카테고리 이름 변경'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '새 카테고리 이름'),
          onSubmitted: (_) => Navigator.pop(ctx, ctl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final newName = result.trim();
    if (newName.isEmpty || newName == oldName) return;

    final exists = _allCategories.any(
      (c) => c.toLowerCase().trim() == newName.toLowerCase(),
    );
    if (exists) {
      snack('이미 존재하는 카테고리입니다.');
      return;
    }

    await _runGuard(() async {
      final rows =
          await _client
                  .from(SupabaseTables.feedbackKeywords)
                  .update({'category': newName})
                  .eq('category', oldName)
                  .select('id')
              as List;

      if (rows.isEmpty) {
        snack('변경 실패: 권한 또는 대상 확인 필요');
        return;
      }

      _keyword.invalidateCache();
      if (_selectedCategory == oldName) _selectedCategory = newName;
      await _loadCategories(force: true);
      snack('카테고리 이름을 "$oldName" → "$newName"로 변경했습니다.');
    });
  }

  // ----- 키워드 CRUD -----
  Future<void> _saveItems(List<KeywordItem> list) async {
    if (_selectedCategory == null) return;

    await _runGuard(() async {
      final rows =
          await _client
                  .from(SupabaseTables.feedbackKeywords)
                  .update({'items': list.map((e) => e.toJson()).toList()})
                  .eq('category', _selectedCategory!)
                  .select('id')
              as List;

      if (rows.isEmpty) {
        snack('저장 실패: 권한 또는 대상 확인 필요');
        return;
      }

      _keyword.invalidateCache();
      await _loadItems(_selectedCategory!, force: true);
      // 필요 시 여기서 성공 토스트
    });
  }

  Future<void> _addKeyword() async {
    if (!_canAct || _selectedCategory == null) return;

    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('카테고리 "${_selectedCategory!}"에 키워드 추가'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 코드 전환'),
          onSubmitted: (_) => Navigator.pop(ctx, ctl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (text == null) return;
    final t = text.trim();
    if (t.isEmpty) return;

    final key = t.toLowerCase().trim();
    final exists = _items.any(
      (e) =>
          e.value.toLowerCase().trim() == key ||
          e.text.toLowerCase().trim() == key,
    );
    if (exists) {
      snack('이미 존재하는 키워드입니다.');
      return;
    }

    final newList = [..._items, KeywordItem(t, t)];
    await _saveItems(newList);
  }

  Future<void> _removeKeyword(KeywordItem item) async {
    if (!_canAct || _selectedCategory == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('키워드 삭제'),
        content: Text('"${item.text}" 키워드를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final newList = _items
        .where((e) => !(e.value == item.value && e.text == item.text))
        .toList();
    await _saveItems(newList);
  }

  Future<void> _editKeyword(KeywordItem oldItem) async {
    if (!_canAct || _selectedCategory == null) return;

    final ctl = TextEditingController(text: oldItem.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('키워드 수정'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '새 키워드 이름'),
          onSubmitted: (_) => Navigator.pop(ctx, ctl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (result == null) return;
    final newText = result.trim();
    if (newText.isEmpty || newText == oldItem.text) return;

    final key = newText.toLowerCase().trim();
    final dup = _items.any((e) {
      final same =
          e.value.toLowerCase().trim() == key ||
          e.text.toLowerCase().trim() == key;
      final isSelf = e.text == oldItem.text && e.value == oldItem.value;
      return same && !isSelf;
    });
    if (dup) {
      snack('이미 존재하는 키워드입니다.');
      return;
    }

    final newList = _items.map((e) {
      if (e.text == oldItem.text && e.value == oldItem.value) {
        return KeywordItem(newText, newText);
      }
      return e;
    }).toList();

    await _saveItems(newList);
  }

  // ----- 정렬 모드 -----
  Future<void> _openReorderDialog() async {
    if (_selectedCategory == null || _items.isEmpty) return;

    List<KeywordItem> working = List.of(_items);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('정렬: ${_selectedCategory!}'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: true,
              itemCount: working.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = working.removeAt(oldIndex);
                working.insert(newIndex, item);
              },
              itemBuilder: (ctx, i) {
                final it = working[i];
                return ListTile(
                  key: ValueKey('${it.value}|${it.text}'),
                  title: Text(
                    it.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: const Icon(Icons.drag_handle),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );

    if (saved == true) {
      await _saveItems(working);
    }
  }

  // ----- UI -----
  @override
  Widget build(BuildContext context) {
    if (!_adminChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('키워드 관리')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 12),
                const Text('관리자 권한이 필요합니다.'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: popIfMounted,
                  child: const Text('뒤로가기'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final hasSelection = _selectedCategory != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('키워드 관리 (관리자 전용)'),
        actions: [
          IconButton(
            tooltip: '캐시 새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: _busy
                ? null
                : () async {
                    _keyword.invalidateCache();
                    await _loadCategories(force: true);
                    snack('캐시 무효화 후 다시 불러왔습니다.');
                  },
          ),
          if (hasSelection) ...[
            IconButton(
              tooltip: '정렬 모드',
              icon: const Icon(Icons.sort),
              onPressed: _busy ? null : _openReorderDialog,
            ),
            IconButton(
              tooltip: '카테고리 이름 변경',
              icon: const Icon(Icons.drive_file_rename_outline),
              onPressed: _busy
                  ? null
                  : () => _renameCategory(_selectedCategory!),
            ),
            IconButton(
              tooltip: '카테고리 삭제',
              icon: const Icon(Icons.delete_forever),
              onPressed: _busy
                  ? null
                  : () => _deleteCategory(_selectedCategory!),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async => _loadCategories(force: true),
              child: Row(
                children: [
                  // 좌측: 카테고리 목록 + 퀵 UI
                  Container(
                    width: 280,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    child: Column(
                      children: [
                        // 빠른 추가 / 검색
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _catQuickAddCtl,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    hintText: '새 카테고리',
                                  ),
                                  onSubmitted: (v) {
                                    final vv = v.trim();
                                    if (vv.isNotEmpty) {
                                      _addCategory(preset: vv);
                                      _catQuickAddCtl.clear();
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: '카테고리 추가',
                                onPressed: _busy
                                    ? null
                                    : () {
                                        final v = _catQuickAddCtl.text.trim();
                                        if (v.isNotEmpty) {
                                          _addCategory(preset: v);
                                          _catQuickAddCtl.clear();
                                        } else {
                                          _addCategory();
                                        }
                                      },
                                icon: const Icon(Icons.create_new_folder),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: TextField(
                            controller: _catFilterCtl,
                            decoration: const InputDecoration(
                              isDense: true,
                              prefixIcon: Icon(Icons.search),
                              hintText: '카테고리 검색',
                            ),
                            onChanged: (_) => setState(() {
                              _applyCategoryFilter();
                            }),
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final c in _filteredCategories)
                                ListTile(
                                  title: Text(
                                    c,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  selected: c == _selectedCategory,
                                  trailing: PopupMenuButton<String>(
                                    tooltip: '더보기',
                                    onSelected: (v) {
                                      if (v == 'rename') _renameCategory(c);
                                      if (v == 'delete') _deleteCategory(c);
                                    },
                                    itemBuilder: (ctx) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: ListTile(
                                          leading: Icon(Icons.edit),
                                          title: Text('이름 변경'),
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: ListTile(
                                          leading: Icon(Icons.delete_outline),
                                          title: Text('삭제'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _loadItems(c),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  // 우측: 키워드 아이템 목록
                  Expanded(
                    child: _selectedCategory == null
                        ? const Center(child: Text('카테고리를 선택하세요'))
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              Row(
                                children: [
                                  Text(
                                    '카테고리: ${_selectedCategory!}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '(${_items.length} 개)',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const Spacer(),
                                  FilledButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : _openReorderDialog,
                                    icon: const Icon(Icons.sort),
                                    label: const Text('정렬 모드'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _items.map((it) {
                                  return InputChip(
                                    label: Text(it.text),
                                    onPressed: _busy
                                        ? null
                                        : () async {
                                            final action =
                                                await showModalBottomSheet<
                                                  String
                                                >(
                                                  context: context,
                                                  builder: (ctx) => SafeArea(
                                                    child: Wrap(
                                                      children: [
                                                        ListTile(
                                                          leading: const Icon(
                                                            Icons.edit,
                                                          ),
                                                          title: const Text(
                                                            '수정',
                                                          ),
                                                          onTap: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                'edit',
                                                              ),
                                                        ),
                                                        ListTile(
                                                          leading: const Icon(
                                                            Icons
                                                                .delete_outline,
                                                          ),
                                                          title: const Text(
                                                            '삭제',
                                                          ),
                                                          onTap: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                'delete',
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                            if (action == 'edit') {
                                              await _editKeyword(it);
                                            } else if (action == 'delete') {
                                              await _removeKeyword(it);
                                            }
                                          },
                                    onDeleted: _busy
                                        ? null
                                        : () => _removeKeyword(it),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: !_isAdmin
          ? null
          : (_selectedCategory == null
                ? FloatingActionButton(
                    onPressed: _busy ? null : _addCategory,
                    tooltip: '새 카테고리',
                    child: const Icon(Icons.create_new_folder),
                  )
                : FloatingActionButton(
                    onPressed: _busy ? null : _addKeyword,
                    tooltip: '키워드 추가',
                    child: const Icon(Icons.add),
                  )),
    );
  }

  @override
  void dispose() {
    _catFilterCtl.dispose();
    _catQuickAddCtl.dispose();
    super.dispose();
  }
}
