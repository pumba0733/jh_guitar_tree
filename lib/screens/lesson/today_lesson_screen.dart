// lib/screens/lesson/today_lesson_screen.dart
// v1.31.0 | 오늘 수업 화면 - 인자 가드/lessonId 옵션 지원/안정성 보강
// - v1.24.4 기반
// 변경점:
//   1) arguments 가드: studentId 누락 시 스낵바+뒤로가기 (throw 제거)
//   2) arguments 확장: lessonId(옵션) 지원 → (해당 학생 && 오늘 날짜)인 경우 해당 행 사용
//   3) mounted/에러 표시 보강, 키워드/저장 흐름 유지, fromHistoryId 프리필 유지

import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../ui/components/file_clip.dart';
import '../../services/lesson_service.dart';
import '../../services/keyword_service.dart';
import '../../services/file_service.dart';
import '../../services/log_service.dart';
import '../../ui/components/save_status_indicator.dart';
import '../../ui/components/drop_upload_area.dart';

enum _LocalSection { memo, nextPlan, link, attach }

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();
  final KeywordService _keyword = KeywordService();
  final FileService _file = FileService();

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _nextCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();
  final _keywordSearchCtl = TextEditingController();

  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  Timer? _debounce;
  Timer? _kwSearchDebounce;

  // 식별자
  String? _lessonId; // (옵션) args.lessonId 또는 ensure에서 생성/조회
  late String _studentId; // (필수) args.studentId
  String? _teacherId; // (옵션) args.teacherId

  // 진입 프리필용
  String? _fromHistoryId; // (옵션) args.fromHistoryId

  // 오늘 날짜 (YYYY-MM-DD)
  late String _todayDateStr;

  // 키워드 (DB) 상태
  List<String> _categories = const [];
  String? _selectedCategory;
  List<KeywordItem> _items = const [];
  List<KeywordItem> _filteredItems = const [];
  final Set<String> _selectedKeywords = {};

  // 최근 다음 계획 후보
  List<String> _recentNextPlans = const [];

  // 첨부
  // attachments: list of `{ "path": "...", "url": "...", "name": "파일.ext", "size": <int?> }`
  final List<Map<String, dynamic>> _attachments = [];

  bool _initialized = false;
  bool _loadingKeywords = false;

  bool get _isDesktop =>
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux) && !kIsWeb;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    // ===== 인자 파싱 & 가드 =====
    final raw = ModalRoute.of(context)?.settings.arguments;
    final args = (raw is Map)
        ? Map<String, dynamic>.from(raw as Map)
        : <String, dynamic>{};

    _studentId = (args['studentId'] as String?)?.trim() ?? '';
    _teacherId = (args['teacherId'] as String?)?.trim();
    _fromHistoryId = (args['fromHistoryId'] as String?)?.trim();
    final argLessonId = (args['lessonId'] as String?)?.trim();

    // 오늘 날짜 문자열 계산
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    _todayDateStr = d0.toIso8601String().split('T').first;

    if (_studentId.isEmpty) {
      // 필수 인자 누락: 안내 후 뒤로가기
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showError('잘못된 진입입니다. 학생 정보가 누락되었습니다.');
        Navigator.maybePop(context);
      });
      return;
    }

    _bindListeners();

    // 비동기 초기화: (선택)lessonId 검증 → 오늘 행 보장 → (선택)히스토리 프리필 → 키워드/최근계획
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsync(initialLessonId: argLessonId);
    });
  }

  Future<void> _initAsync({String? initialLessonId}) async {
    // 1) (옵션) lessonId로 먼저 시도: 해당 학생 && 오늘 날짜면 사용
    if (initialLessonId != null && initialLessonId.isNotEmpty) {
      try {
        final row = await _service.getById(initialLessonId);
        if (row != null) {
          final sid = (row['student_id'] ?? '').toString();
          final dateStr = (row['date'] ?? '').toString();
          if (sid == _studentId && dateStr == _todayDateStr) {
            _applyRow(row);
          }
        }
      } catch (_) {
        // 무시하고 ensureTodayRow로 진행
      }
    }

    // 2) 오늘 행 보장(이미 _lessonId가 채워졌으면 내부에서 그대로 유지)
    await _ensureTodayRow();

    // 3) (옵션) 히스토리 프리필
    if (_fromHistoryId != null && _fromHistoryId!.isNotEmpty) {
      await _prefillFromHistory(_fromHistoryId!);
    }

    // 4) 키워드/최근 계획 로딩
    await _loadKeywordData();
    await _loadRecentNextPlans();
  }

  void _bindListeners() {
    _subjectCtl.addListener(_scheduleSave);
    _memoCtl.addListener(_scheduleSave);
    _nextCtl.addListener(_scheduleSave);
    _youtubeCtl.addListener(_scheduleSave);

    // 키워드 검색창: 200ms 디바운스 후 전역 검색
    _keywordSearchCtl.addListener(() {
      _kwSearchDebounce?.cancel();
      _kwSearchDebounce = Timer(
        const Duration(milliseconds: 200),
        () => _applyKeywordSearch(),
      );
      // suffixIcon(지우기 버튼) 표시/숨김 갱신
      setState(() {});
    });
  }

  Future<void> _ensureTodayRow() async {
    try {
      // 이미 lessonId가 세팅되어 있으면 현재 값으로 필드/선택 상태만 재세팅하고 리턴
      if (_lessonId != null && _lessonId!.isNotEmpty) {
        final row = await _service.getById(_lessonId!);
        if (row != null) {
          _applyRow(row);
          return;
        }
        // 못 찾으면 신규 보장 로직으로 진행
      }

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
        row = await _service.upsert({
          'student_id': _studentId,
          if (_teacherId != null && _teacherId!.isNotEmpty)
            'teacher_id': _teacherId,
          'date': _todayDateStr,
          'subject': '',
          'memo': '',
          'next_plan': '',
          'keywords': <String>[],
          'attachments': <Map<String, dynamic>>[],
          'youtube_url': '',
        });
      }

      _applyRow(row);
    } catch (e) {
      _showError('오늘 수업 데이터를 불러오지 못했어요.\n$e');
    }
  }

  void _applyRow(Map<String, dynamic> row) {
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

    final atts = row['attachments'];
    if (atts is List) {
      _attachments
        ..clear()
        ..addAll(
          atts.map<Map<String, dynamic>>((e) {
            if (e is Map) return Map<String, dynamic>.from(e);
            final v = e.toString();
            return {'path': v, 'url': v};
          }),
        );
    }

    if (mounted) setState(() {});
  }

  /// 히스토리에서 넘어온 레슨을 오늘 레슨에 프리필
  Future<void> _prefillFromHistory(String historyId) async {
    try {
      final row = await _service.getById(historyId);
      if (row == null) {
        _showError('복습할 기록을 찾을 수 없습니다.');
        return;
      }

      // 주제/메모/키워드/링크만 프리필 (첨부는 복사하지 않음)
      final subject = (row['subject'] ?? '').toString();
      final memo = (row['memo'] ?? '').toString();
      final nextPlan = (row['next_plan'] ?? '').toString();
      final youtube = (row['youtube_url'] ?? '').toString();
      final kw = (row['keywords'] is List)
          ? (row['keywords'] as List)
          : const [];

      _subjectCtl.text = subject;
      _memoCtl.text = memo;
      _nextCtl.text = nextPlan;
      _youtubeCtl.text = youtube;

      _selectedKeywords
        ..clear()
        ..addAll(kw.map((e) => e.toString()));

      setState(() {});
      _scheduleSave(); // 프리필 즉시 저장
    } catch (e) {
      _showError('복습 프리필 중 오류가 발생했어요: $e');
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
          _filteredItems = _items;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _categories = categories;
          _selectedCategory = selectedCat;
          _items = items;
          _filteredItems = items;
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
        _filteredItems = _items;
      });
      _showError('키워드 목록을 불러오지 못했어요. 기본 목록으로 대체합니다.\n$e');
    } finally {
      if (mounted) setState(() => _loadingKeywords = false);
    }
  }

  Future<void> _loadRecentNextPlans() async {
    try {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final list = await _service.listByStudent(
        _studentId,
        to: yesterday,
        limit: 20,
      );
      final seen = <String>{};
      final candidates = <String>[];
      for (final r in list) {
        final np = (r['next_plan'] ?? '').toString().trim();
        if (np.isEmpty) continue;
        if (seen.add(np)) candidates.add(np);
        if (candidates.length >= 3) break;
      }
      if (!mounted) return;
      setState(() => _recentNextPlans = candidates);
    } catch (_) {
      // 선택 기능: 실패 시 무시
    }
  }

  Future<void> _applyKeywordSearch() async {
    final q = _keywordSearchCtl.text.trim();
    if (q.isEmpty) {
      _filteredItems = _items;
      if (mounted) setState(() {});
      return;
    }
    try {
      final hits = await _keyword.searchItems(q);
      if (!mounted) return;
      setState(() => _filteredItems = hits.isNotEmpty ? hits : _items);
    } catch (_) {
      if (mounted) setState(() => _filteredItems = _items);
    }
  }

  void _scheduleSave() {
    _setStatus(SaveStatus.saving);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _saveInternal);
  }

  Future<void> _saveInternal() async {
    if (_lessonId == null || _lessonId!.isEmpty) return;
    try {
      // 저장용으로 localPath 제거
      final attachmentsForSave = _attachments.map((m) {
        final c = Map<String, dynamic>.from(m);
        c.remove('localPath');
        return c;
      }).toList();

      await _service.upsert({
        'id': _lessonId,
        'student_id': _studentId,
        'date': _todayDateStr,
        if (_teacherId != null && _teacherId!.isNotEmpty)
          'teacher_id': _teacherId,
        'subject': _subjectCtl.text.trim(),
        'memo': _memoCtl.text.trim(),
        'next_plan': _nextCtl.text.trim(),
        'keywords': _selectedKeywords.toList(),
        'attachments': attachmentsForSave,
        'youtube_url': _youtubeCtl.text.trim(),
      });
      _lastSavedAt = DateTime.now();
      _setStatus(SaveStatus.saved);

      // 로그 기록
      unawaited(
        LogService.insertLog(
          type: 'lesson_save',
          payload: {
            'lesson_id': _lessonId,
            'student_id': _studentId,
            'date': _todayDateStr,
          },
        ),
      );
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

  Future<void> _handleUploadAttachments() async {
    if (!_isDesktop) return;
    try {
      final picked = await _file.pickAndUploadMultiple(
        studentId: _studentId,
        dateStr: _todayDateStr,
      );
      for (final e in picked) {
        _attachments.add({
          'path': e['path'],
          'url': e['url'] ?? e['path'],
          'name': e['name'] ?? (e['path'] ?? 'file'),
          'size': e['size'],
        });
      }
      setState(() {});
      _scheduleSave();
    } catch (e) {
      _showError('첨부 업로드 실패: $e');
    }
  }

  Future<void> _handleOpenAttachment(Map<String, dynamic> att) async {
    try {
      await _file.openAttachment(att);
    } catch (e) {
      _showError('파일 열기 실패: $e');
    }
  }

  Future<void> _handleRemoveAttachment(int index) async {
    try {
      final removed = _attachments.removeAt(index);
      setState(() {});
      _scheduleSave();

      final urlOrPath = (removed['url'] ?? removed['path'] ?? '').toString();
      if (urlOrPath.isNotEmpty) {
        unawaited(_file.delete(urlOrPath));
      }
    } catch (e) {
      _showError('첨부 삭제 실패: $e');
    }
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
    _kwSearchDebounce?.cancel();
    _subjectCtl.dispose();
    _memoCtl.dispose();
    _nextCtl.dispose();
    _youtubeCtl.dispose();
    _keywordSearchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAttach = _isDesktop;

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
          _buildKeywordSearchBox(),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_recentNextPlans.isNotEmpty) ...[
                  Text(
                    '최근 계획 가져오기',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _recentNextPlans.map((t) {
                      return ActionChip(
                        label: Text(
                          t,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () {
                          _nextCtl.text = t;
                          _scheduleSave();
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _nextCtl,
                  decoration: const InputDecoration(
                    hintText: '다음 시간에 할 계획을 적어두세요',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                ),
              ],
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
                    onSubmitted: (_) async {
                      final url = _youtubeCtl.text.trim();
                      if (url.isEmpty) return;
                      try {
                        await _file.openUrl(url); // 외부 브라우저
                      } catch (e) {
                        _showError('링크 열기 실패: $e');
                      }
                      _scheduleSave();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    final url = _youtubeCtl.text.trim();
                    if (url.isEmpty) return;
                    try {
                      await _file.openUrl(url); // 외부 브라우저
                    } catch (e) {
                      _showError('링크 열기 실패: $e');
                    }
                  },
                  child: const Text('열기'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _buildExpandable(
            title: '📎 첨부 파일',
            section: _LocalSection.attach,
            child: canAttach ? _attachmentDesktop() : _platformNotice(),
          ),
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
                  setState(() {
                    _items = items;
                  });
                  await _applyKeywordSearch();
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

  Widget _buildKeywordSearchBox() {
    return TextField(
      controller: _keywordSearchCtl,
      decoration: InputDecoration(
        hintText: '키워드 검색…',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _keywordSearchCtl.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _keywordSearchCtl.clear();
                  _applyKeywordSearch();
                },
              ),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildKeywordChips() {
    return Padding(
      key: _keywordsKey,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _filteredItems.map((it) {
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

  Widget _attachmentDesktop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: _handleUploadAttachments,
              icon: const Icon(Icons.upload_file),
              label: const Text('업로드'),
            ),
            const SizedBox(width: 8),
            Text(
              '드래그&드롭 또는 버튼으로 업로드',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 12),

        DropUploadArea(
          studentId: _studentId,
          dateStr: _todayDateStr,
          onUploaded: (list) {
            for (final e in list) {
              _attachments.add({
                'path': e['path'],
                'url': e['url'] ?? e['path'],
                'name': e['name'] ?? (e['path'] ?? 'file'),
                'size': e['size'],
              });
            }
            setState(() {});
            _scheduleSave();
          },
          onError: (err) => _showError('드래그 업로드 실패: $err'),
        ),

        const SizedBox(height: 12),
        if (_attachments.isEmpty)
          Text('첨부 없음', style: Theme.of(context).textTheme.bodySmall),
        if (_attachments.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_attachments.length, (i) {
              final att = _attachments[i];
              final name = (att['name'] ?? att['path'] ?? 'file').toString();
              return FileClip(
                name: name,
                path: (att['path'] ?? '').toString().isNotEmpty
                    ? att['path']
                    : null,
                url: (att['url'] ?? '').toString().isNotEmpty
                    ? att['url']
                    : null,
                onDelete: () => _handleRemoveAttachment(i),
              );
            }),
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

  Widget _buildExpandable({
    required String title,
    required _LocalSection section,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [child],
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
