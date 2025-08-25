// lib/screens/lesson/today_lesson_screen.dart
// v1.22.1 | 학생용 오늘 수업 화면 (디바운스 자동저장/키워드/접힘 섹션) - currentTeacher 참조 제거 & unnecessary_cast 정리
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/lesson_service.dart';
import '../../services/auth_service.dart';
import '../../ui/components/save_status_indicator.dart';

enum _LocalSection { memo, nextPlan, link }

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _nextCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();

  // 저장 상태
  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  Timer? _debounce;

  // 식별자
  String? _lessonId;
  late String _studentId;
  String? _teacherId;

  // 키워드 프리셋 (임시)
  final List<String> _allKeywords = const [
    '박자',
    '코드 전환',
    '리듬',
    '운지',
    '스케일',
    '톤',
    '댐핑',
  ];
  final Set<String> _selectedKeywords = {};

  // 접힘 상태
  final Map<_LocalSection, bool> _expanded = {
    _LocalSection.memo: false,
    _LocalSection.nextPlan: false,
    _LocalSection.link: false,
  };

  bool _initialized = false;
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

    // ⚠️ AuthService에는 currentTeacher가 없음 → args로만 teacherId 수신
    _teacherId = args?['teacherId'] as String?;

    if (_studentId.isEmpty) {
      throw Exception('TodayLessonScreen requires studentId');
    }

    _bindListeners();
    _ensureTodayRow();
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
      final dateStr = d0.toIso8601String().split('T').first;

      final list = await _service.listByStudent(
        _studentId,
        from: d0,
        to: d0,
        limit: 1,
      );

      Map<String, dynamic> row;
      if (list.isNotEmpty) {
        // unnecessary_cast 제거: listByStudent 반환이 이미 List<Map<String,dynamic>>
        row = list.first;
      } else {
        // unnecessary_cast 제거: upsert 반환이 Map<String,dynamic>
        row = await _service.upsert({
          'student_id': _studentId,
          if (_teacherId != null) 'teacher_id': _teacherId,
          'date': dateStr,
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
      // enum 명칭 통일: failed 사용
      _setStatus(SaveStatus.failed);
      _showError('저장 실패: $e');
    }
  }

  void _toggleKeyword(String k) {
    if (_selectedKeywords.contains(k)) {
      _selectedKeywords.remove(k);
    } else {
      _selectedKeywords.add(k);
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

  Widget _buildKeywordChips() {
    return Padding(
      key: _keywordsKey,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _allKeywords.map((k) {
          final selected = _selectedKeywords.contains(k);
          return FilterChip(
            label: Text(k),
            selected: selected,
            onSelected: (_) => _toggleKeyword(k),
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
