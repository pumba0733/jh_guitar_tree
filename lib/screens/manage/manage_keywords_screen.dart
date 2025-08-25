// lib/screens/manage/manage_keywords_screen.dart
// v1.24.3 | 관리자 전용 키워드 관리 화면
// - 카테고리/아이템 CRUD + 키워드 이름 변경 + 카테고리 이름 변경
// - KeywordService 캐시 invalidate + Supabase 연동
// - AppBar: 캐시 새로고침, 현재 카테고리 삭제/이름변경
//
// 설계 메모:
// - 카테고리 rename은 feedback_keywords.category 값을 업데이트하는 단순 방식
// - rename 시 동일 이름 존재하면 거부(중복 방지)
// - 모든 갱신 후 KeywordService.invalidateCache() + 재조회로 일관성 유지

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

  String? _selectedCategory;
  List<String> _categories = [];
  List<KeywordItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories({bool force = false}) async {
    setState(() => _loading = true);
    final cats = await _keyword.fetchCategories(force: force);
    setState(() {
      _categories = cats;
      // 선택 유지: 기존 선택이 목록에 있으면 유지, 아니면 첫 항목
      if (_selectedCategory != null && cats.contains(_selectedCategory)) {
        // keep
      } else {
        _selectedCategory = cats.isNotEmpty ? cats.first : null;
      }
    });
    if (_selectedCategory != null) {
      await _loadItems(_selectedCategory!, force: force);
    } else {
      setState(() => _items = []);
    }
    setState(() => _loading = false);
  }

  Future<void> _loadItems(String category, {bool force = false}) async {
    final list = await _keyword.fetchItemsByCategory(category, force: force);
    setState(() {
      _selectedCategory = category;
      _items = list;
    });
  }

  // ---------- 카테고리 CRUD ----------
  Future<void> _addCategory() async {
    final ctl = TextEditingController();
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

    // 중복 방지
    if (_categories
        .map((e) => e.toLowerCase().trim())
        .contains(n.toLowerCase())) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이미 존재하는 카테고리입니다.')));
      }
      return;
    }

    await _client.from(SupabaseTables.feedbackKeywords).insert({
      'category': n,
      'items': [],
    });
    _keyword.invalidateCache();
    await _loadCategories(force: true);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('카테고리 "$n" 추가됨')));
    }
  }

  Future<void> _deleteCategory(String category) async {
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

    await _client
        .from(SupabaseTables.feedbackKeywords)
        .delete()
        .eq('category', category);
    _keyword.invalidateCache();
    if (_selectedCategory == category) _selectedCategory = null;
    await _loadCategories(force: true);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('카테고리 "$category" 삭제 완료')));
    }
  }

  Future<void> _renameCategory(String oldName) async {
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

    // 중복 방지
    final exists = _categories
        .where((c) => c.toLowerCase().trim() == newName.toLowerCase())
        .isNotEmpty;
    if (exists) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이미 존재하는 카테고리입니다.')));
      }
      return;
    }

    // 단순 rename: category 필드 업데이트
    await _client
        .from(SupabaseTables.feedbackKeywords)
        .update({'category': newName})
        .eq('category', oldName);

    _keyword.invalidateCache();

    // 선택 상태 유지: 기존 선택이 oldName이었다면 새 이름으로 바꿔줌
    if (_selectedCategory == oldName) {
      _selectedCategory = newName;
    }
    await _loadCategories(force: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('카테고리 이름을 "$oldName" → "$newName"로 변경했습니다.')),
      );
    }
  }

  // ---------- 키워드 CRUD ----------
  Future<void> _saveItems(List<KeywordItem> list) async {
    if (_selectedCategory == null) return;
    await _client
        .from(SupabaseTables.feedbackKeywords)
        .update({'items': list.map((e) => e.toJson()).toList()})
        .eq('category', _selectedCategory!);
    _keyword.invalidateCache();
    await _loadItems(_selectedCategory!, force: true);
  }

  Future<void> _addKeyword() async {
    if (_selectedCategory == null) return;
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

    // 중복 방지(대소문자/공백 무시)
    final key = t.toLowerCase().trim();
    final exists = _items.any(
      (e) =>
          e.value.toLowerCase().trim() == key ||
          e.text.toLowerCase().trim() == key,
    );
    if (exists) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이미 존재하는 키워드입니다.')));
      }
      return;
    }

    final newList = [..._items, KeywordItem(t, t)];
    await _saveItems(newList);
  }

  Future<void> _removeKeyword(KeywordItem item) async {
    if (_selectedCategory == null) return;
    final newList = _items
        .where((e) => !(e.value == item.value && e.text == item.text))
        .toList();
    await _saveItems(newList);
  }

  Future<void> _editKeyword(KeywordItem oldItem) async {
    if (_selectedCategory == null) return;

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

    // 중복 방지
    final key = newText.toLowerCase();
    final dup = _items.any((e) {
      final same =
          e.value.toLowerCase().trim() == key ||
          e.text.toLowerCase().trim() == key;
      final isSelf = e.text == oldItem.text && e.value == oldItem.value;
      return same && !isSelf;
    });
    if (dup) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이미 존재하는 키워드입니다.')));
      }
      return;
    }

    // rename: text/value를 동일하게 변경
    final newList = _items.map((e) {
      if (e.text == oldItem.text && e.value == oldItem.value) {
        return KeywordItem(newText, newText);
      }
      return e;
    }).toList();

    await _saveItems(newList);
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedCategory != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('키워드 관리 (관리자 전용)'),
        actions: [
          IconButton(
            tooltip: '캐시 새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              _keyword.invalidateCache();
              await _loadCategories(force: true);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('캐시 무효화 후 다시 불러왔습니다.')),
                );
              }
            },
          ),
          if (hasSelection) ...[
            IconButton(
              tooltip: '카테고리 이름 변경',
              icon: const Icon(Icons.drive_file_rename_outline),
              onPressed: () => _renameCategory(_selectedCategory!),
            ),
            IconButton(
              tooltip: '카테고리 삭제',
              icon: const Icon(Icons.delete_forever),
              onPressed: () => _deleteCategory(_selectedCategory!),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // 좌측: 카테고리 목록
                Container(
                  width: 240,
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceVariant.withOpacity(0.5),
                  child: ListView(
                    children: [
                      for (final c in _categories)
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
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(
                                value: 'rename',
                                child: ListTile(
                                  leading: Icon(Icons.edit),
                                  title: Text('이름 변경'),
                                ),
                              ),
                              const PopupMenuItem(
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
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '(${_items.length} 개)',
                                  style: Theme.of(context).textTheme.bodySmall,
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
                                  onPressed: () async {
                                    // Chip 클릭 → 수정/삭제 액션
                                    final action =
                                        await showModalBottomSheet<String>(
                                          context: context,
                                          builder: (ctx) => SafeArea(
                                            child: Wrap(
                                              children: [
                                                ListTile(
                                                  leading: const Icon(
                                                    Icons.edit,
                                                  ),
                                                  title: const Text('수정'),
                                                  onTap: () => Navigator.pop(
                                                    ctx,
                                                    'edit',
                                                  ),
                                                ),
                                                ListTile(
                                                  leading: const Icon(
                                                    Icons.delete_outline,
                                                  ),
                                                  title: const Text('삭제'),
                                                  onTap: () => Navigator.pop(
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
                                  onDeleted: () => _removeKeyword(it),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                ),
              ],
            ),
      floatingActionButton: _selectedCategory == null
          ? FloatingActionButton(
              onPressed: _addCategory,
              tooltip: '새 카테고리',
              child: const Icon(Icons.create_new_folder),
            )
          : FloatingActionButton(
              onPressed: _addKeyword,
              tooltip: '키워드 추가',
              child: const Icon(Icons.add),
            ),
    );
  }
}
