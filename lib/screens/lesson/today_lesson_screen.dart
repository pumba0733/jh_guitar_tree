// lib/screens/lesson/today_lesson_screen.dart
// v1.23.1 | 오늘 수업 화면 - 키워드 DB 연동 + 디바운스 자동저장
// - FIX: onConflict(student_id,date) 대응 위해 저장 시 항상 'date' 포함
// - FIX: 키워드 새로고침 버튼: invalidateCache 후 로드 재실행(서비스 수정 불필요)

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/lesson_service.dart';
import '../../services/auth_service.dart';
import '../../services/keyword_service.dart';
import '../../ui/components/save_status_indicator.dart';

enum _LocalSection { memo, nextPlan, link }

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();
  final KeywordService _keyword = KeywordService();

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _nextCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();

  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  Timer? _debounce;

  // 식별자
  String? _lessonId;
  late String _studentId;
  String? _teacherId;

  // 오늘 날짜 (YYYY-MM-DD)
  late final String _todayDateStr;

  // 키워드 (DB) 상태
  List<String> _categories = const [];
  String? _selectedCategory;
  List<KeywordItem> _items = const [];
  final Set<String> _selectedKeywords = {};

  // 접힘 상태
  final Map<_LocalSection, bool> _expanded = {
    _LocalSection.memo: false,
    _LocalSection.nextPlan: false,
    _LocalSection.link: false,
  };

  bool _initialized = false;
  bool _loadingKeywords = false;

  bool get _isDesktop =>
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;

    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _studentId =
        (args?['studentId'] as String?) ??
        AuthService().currentStudent?.id ??
        '';

    _teacherId = args?['teacherId'] as String?;

    if (_studentId.isEmpty) {
      throw Exception('TodayLessonScreen requires studentId');
    }

    // 오늘 날짜 문자열 확정
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    _todayDateStr = d0.toIso8601String().split('T').first;

    _bindListeners();
    _ensureTodayRow();
    _loadKeywordData();
    _initialized = true;
  }

  void _bindListeners() {
    _subjectCtl.addListener(_scheduleSave);
    _memoCtl.addListener(_scheduleSave);
    _nextCtl.addListener(_scheduleSave);
    _youtubeCtl.addListener(_scheduleSave);
  }

  Future<void> _ensureTodayRow() async {
    try {
      final today = DateTime.now();
      final d0 = DateTime(today.year, today.month, today.day);

      final list = await _service.listByStudent(
        _studentId,
        from: d0,
        to: d0,
        limit: 1,
      );

      Map<String, dynamic> row;
      if (list.isNotEmpty) {
        row = list.first;
      } else {
        // 최초 생성 시에도 date를 명시
        row = await _service.upsert({
          'student_id': _studentId,
          if (_teacherId != null) 'teacher_id': _teacherId,
          'date': _todayDateStr,
          'subject': '',
          'memo': '',
          'next_plan': '',
          'keywords': <String>[],
          'youtube_url': '',
        });
      }

      _lessonId = row['id']?.toString();
      _subjectCtl.text = (row['subject'] ?? '').toString();
      _memoCtl.text = (row['memo'] ?? '').toString();
      _nextCtl.text = (row['next_plan'] ?? '').toString();
      _youtubeCtl.text = (row['youtube_url'] ?? '').toString();

      final kw = row['keywords'];
      if (kw is List) {
        _selectedKeywords
          ..clear()
          ..addAll(kw.map((e) => e.toString()));
      }

      if (mounted) setState(() {});
    } catch (e) {
      _showError('오늘 수업 데이터를 불러오지 못했어요.\n$e');
    }
  }

  Future<void> _loadKeywordData() async {
    setState(() => _loadingKeywords = true);

    try {
      final categories = await _keyword.fetchCategories();
      var selectedCat = (categories.isNotEmpty) ? categories.first : null;
      var items = <KeywordItem>[];

      if (selectedCat != null) {
        items = await _keyword.fetchItemsByCategory(selectedCat);
      }

      // DB 비어있을 때 안전한 fallback
      if (categories.isEmpty || items.isEmpty) {
        selectedCat ??= '기본';
        final mutable = categories.isEmpty ? <String>['기본'] : categories;
        if (!mounted) return;
        setState(() {
          _categories = mutable;
          _selectedCategory = selectedCat;
          _items = const [
            KeywordItem('박자', '박자'),
            KeywordItem('코드 전환', '코드 전환'),
            KeywordItem('리듬', '리듬'),
            KeywordItem('운지', '운지'),
            KeywordItem('스케일', '스케일'),
            KeywordItem('톤', '톤'),
            KeywordItem('댐핑', '댐핑'),
          ];
        });
      } else {
        if (!mounted) return;
        setState(() {
          _categories = categories;
          _selectedCategory = selectedCat;
          _items = items;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _categories = const ['기본'];
        _selectedCategory = '기본';
        _items = const [
          KeywordItem('박자', '박자'),
          KeywordItem('코드 전환', '코드 전환'),
          KeywordItem('리듬', '리듬'),
          KeywordItem('운지', '운지'),
          KeywordItem('스케일', '스케일'),
          KeywordItem('톤', '톤'),
          KeywordItem('댐핑', '댐핑'),
        ];
      });
      _showError('키워드 목록을 불러오지 못했어요. 기본 목록으로 대체합니다.\n$e');
    } finally {
      if (mounted) setState(() => _loadingKeywords = false);
    }
  }

  void _scheduleSave() {
    _setStatus(SaveStatus.saving);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _saveInternal);
  }

  Future<void> _saveInternal() async {
    if (_lessonId == null) return;
    try {
      await _service.upsert({
        'id': _lessonId,
        'student_id': _studentId,
        // onConflict(student_id,date) 대응: 항상 날짜 포함!
        'date': _todayDateStr,
        if (_teacherId != null) 'teacher_id': _teacherId,
        'subject': _subjectCtl.text.trim(),
        'memo': _memoCtl.text.trim(),
        'next_plan': _nextCtl.text.trim(),
        'keywords': _selectedKeywords.toList(),
        'youtube_url': _youtubeCtl.text.trim(),
      });
      _lastSavedAt = DateTime.now();
      _setStatus(SaveStatus.saved);
    } catch (e) {
      _setStatus(SaveStatus.failed);
      _showError('저장 실패: $e');
    }
  }

  void _toggleKeyword(String value) {
    if (_selectedKeywords.contains(value)) {
      _selectedKeywords.remove(value);
    } else {
      _selectedKeywords.add(value);
    }
    setState(() {});
    _scheduleSave();
  }

  void _setStatus(SaveStatus s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subjectCtl.dispose();
    _memoCtl.dispose();
    _nextCtl.dispose();
    _youtubeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAttach = _isDesktop && !kIsWeb;

    return Scaffold(
      appBar: AppBar(title: const Text('오늘 수업')),
      body: _buildBody(canAttach),
      bottomNavigationBar: _buildSaveBar(),
    );
  }

  Widget _buildBody(bool canAttach) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('주제'),
          TextField(
            controller: _subjectCtl,
            decoration: const InputDecoration(
              hintText: '예: 코드 전환 + 다운업 스트로크',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) {
              Scrollable.ensureVisible(
                _keywordsKey.currentContext ?? context,
                duration: const Duration(milliseconds: 250),
              );
            },
          ),
          const SizedBox(height: 16),

          _sectionTitle('키워드'),
          _buildKeywordControls(),
          const SizedBox(height: 8),
          _buildKeywordChips(),

          const SizedBox(height: 8),
          _buildExpandable(
            title: '✏️ 수업 메모',
            section: _LocalSection.memo,
            child: TextField(
              controller: _memoCtl,
              decoration: const InputDecoration(
                hintText: '수업 중 메모를 기록하세요',
                border: OutlineInputBorder(),
              ),
              maxLines: 6,
            ),
          ),
          const SizedBox(height: 8),
          _buildExpandable(
            title: '🗓️ 다음 계획',
            section: _LocalSection.nextPlan,
            child: TextField(
              controller: _nextCtl,
              decoration: const InputDecoration(
                hintText: '다음 시간에 할 계획을 적어두세요',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
          ),
          const SizedBox(height: 8),
          _buildExpandable(
            title: '▶️ 유튜브 링크',
            section: _LocalSection.link,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _youtubeCtl,
                    decoration: const InputDecoration(
                      hintText: 'https://youtu.be/...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final url = _youtubeCtl.text.trim();
                    if (url.isEmpty) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('링크 열기: $url')));
                  },
                  child: const Text('열기'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          if (canAttach) _attachmentStub() else _platformNotice(),
        ],
      ),
    );
  }

  final GlobalKey _keywordsKey = GlobalKey();

  Widget _buildKeywordControls() {
    if (_loadingKeywords) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    return Row(
      children: [
        Expanded(
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '카테고리',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _selectedCategory,
                items: _categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _selectedCategory = v);
                  final items = await _keyword.fetchItemsByCategory(v);
                  if (!mounted) return;
                  setState(() => _items = items);
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '키워드 새로고침 (관리자 편집 반영)',
          child: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              // 서비스 수정 없이 캐시 무효화 후 다시 로드
              _keyword.invalidateCache();
              await _loadKeywordData();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('키워드 캐시를 초기화하고 다시 불러왔어요.')),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildKeywordChips() {
    return Padding(
      key: _keywordsKey,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _items.map((it) {
          final selected = _selectedKeywords.contains(it.value);
          return FilterChip(
            label: Text(it.text),
            selected: selected,
            onSelected: (_) => _toggleKeyword(it.value),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildExpandable({
    required String title,
    required _LocalSection section,
    required Widget child,
  }) {
    final isOpen = _expanded[section] ?? false;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        initiallyExpanded: isOpen,
        onExpansionChanged: (v) => setState(() => _expanded[section] = v),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [child],
      ),
    );
  }

  Widget _attachmentStub() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('📎 첨부 파일 (데스크탑)'),
        const SizedBox(height: 8),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('파일 선택 다이얼로그는 추후 연동 예정')),
                );
              },
              icon: const Icon(Icons.attach_file),
              label: const Text('파일 첨부'),
            ),
            const SizedBox(width: 8),
            Text(
              '첨부/실행은 데스크탑에서 지원됩니다.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _platformNotice() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '⚠️ 모바일/Web에서는 첨부/실행 기능이 제한됩니다. 데스크탑에서 사용해주세요.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Colors.orange),
      ),
    );
  }

  Widget _buildSaveBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SaveStatusIndicator(status: _status, lastSavedAt: _lastSavedAt),
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        t,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    );
  }
}
