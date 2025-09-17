// lib/screens/lesson/today_lesson_screen.dart
// v1.46.0 | "다음 계획" 전면 제거 (UI/상태/저장 로직)
// - next_plan 컨트롤러/상태/초기화/프리필/저장 필드 제거
// - 관련 보조 로딩(_loadRecentNextPlans) 및 UI 섹션 삭제
// - 링크/키워드/메모/첨부/유튜브 기능은 그대로 유지

import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/components/file_clip.dart';
import '../../services/lesson_service.dart';
import '../../services/keyword_service.dart';
import '../../services/file_service.dart';
import '../../services/log_service.dart';
import '../../ui/components/save_status_indicator.dart';
import '../../ui/components/drop_upload_area.dart';

import '../../services/lesson_links_service.dart';
import '../../services/curriculum_service.dart';
import '../../services/resource_service.dart';
import '../../models/resource.dart';

enum _LocalSection { memo, link, attach, lessonLinks }

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});

  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();
  final KeywordService _keyword = KeywordService();
  final FileService _file = FileService();

  // 링크/커리큘럼/리소스
  final LessonLinksService _links = LessonLinksService();
  final CurriculumService _curr = CurriculumService();
  final ResourceService _res = ResourceService();
  String get _defaultResourceBucket => ResourceService.bucket;

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();
  final _keywordSearchCtl = TextEditingController();

  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  Timer? _debounce;
  Timer? _kwSearchDebounce;

  // 식별자
  String? _lessonId;
  late String _studentId;
  String? _teacherId;

  // 진입 프리필용
  String? _fromHistoryId;

  // 오늘 날짜 (YYYY-MM-DD)
  late String _todayDateStr;

  // 키워드 (DB) 상태
  List<String> _categories = const [];
  String? _selectedCategory;
  List<KeywordItem> _items = const [];
  List<KeywordItem> _filteredItems = const [];
  final Set<String> _selectedKeywords = {};

  // 첨부
  final List<Map<String, dynamic>> _attachments = [];

  // 오늘 레슨 링크
  List<Map<String, dynamic>> _todayLinks = const [];
  bool _loadingLinks = false;

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
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    _studentId = (args['studentId'] as String?)?.trim() ?? '';
    _teacherId = (args['teacherId'] as String?)?.trim();
    _fromHistoryId = (args['fromHistoryId'] as String?)?.trim();
    final argLessonId = (args['lessonId'] as String?)?.trim();

    // 오늘 날짜 문자열
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    _todayDateStr = d0.toIso8601String().split('T').first;

    if (_studentId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showError('잘못된 진입입니다. 학생 정보가 누락되었습니다.');
        Navigator.maybePop(context);
      });
      return;
    }

    _bindListeners();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsync(initialLessonId: argLessonId);
    });
  }

  Future<void> _initAsync({String? initialLessonId}) async {
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
      } catch (_) {}
    }

    await _ensureTodayRow();

    if (_fromHistoryId != null && _fromHistoryId!.isNotEmpty) {
      await _prefillFromHistory(_fromHistoryId!);
    }

    await _loadKeywordData();

    // 오늘 레슨 링크 로드
    unawaited(_reloadLessonLinks());
  }

  void _bindListeners() {
    _subjectCtl.addListener(_scheduleSave);
    _memoCtl.addListener(_scheduleSave);
    _youtubeCtl.addListener(_scheduleSave);

    _keywordSearchCtl.addListener(() {
      _kwSearchDebounce?.cancel();
      _kwSearchDebounce = Timer(
        const Duration(milliseconds: 200),
        () => _applyKeywordSearch(),
      );
      if (mounted) setState(() {});
    });
  }

  Future<void> _ensureTodayRow() async {
    try {
      if (_lessonId != null && _lessonId!.isNotEmpty) {
        final row = await _service.getById(_lessonId!);
        if (row != null) {
          _applyRow(row);
          return;
        }
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
          // 'next_plan': ''  // 제거
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

  Future<void> _prefillFromHistory(String historyId) async {
    try {
      final row = await _service.getById(historyId);
      if (row == null) {
        if (!mounted) return;
        _showError('복습할 기록을 찾을 수 없습니다.');
        return;
      }

      final subject = (row['subject'] ?? '').toString();
      final memo = (row['memo'] ?? '').toString();
      final youtube = (row['youtube_url'] ?? '').toString();
      final kw = (row['keywords'] is List)
          ? (row['keywords'] as List)
          : const [];

      _subjectCtl.text = subject;
      _memoCtl.text = memo;
      _youtubeCtl.text = youtube;

      _selectedKeywords
        ..clear()
        ..addAll(kw.map((e) => e.toString()));

      if (mounted) setState(() {});
      _scheduleSave();
    } catch (e) {
      if (!mounted) return;
      _showError('복습 프리필 중 오류가 발생했어요: $e');
    }
  }

  Future<void> _loadKeywordData() async {
    if (mounted) setState(() => _loadingKeywords = true);
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
        'keywords': _selectedKeywords.toList(),
        'attachments': attachmentsForSave,
        'youtube_url': _youtubeCtl.text.trim(),
      });
      _lastSavedAt = DateTime.now();
      _setStatus(SaveStatus.saved);

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

  // ===== 오늘 레슨 링크 로딩/조작 =====
  Future<void> _reloadLessonLinks({bool ensure = false}) async {
    if (mounted) setState(() => _loadingLinks = true);
    try {
      final list = await _links.listTodayByStudent(_studentId, ensure: ensure);
      if (!mounted) return;
      setState(() => _todayLinks = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _todayLinks = const []);
    } finally {
      if (mounted) setState(() => _loadingLinks = false);
    }
  }

  Future<void> _removeLessonLink(String id) async {
    try {
      final ok = await _links.deleteById(id, studentId: _studentId);
      if (!ok) throw StateError('권한 또는 네트워크 오류');
      await _reloadLessonLinks();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('링크를 삭제했습니다.')));
    } catch (e) {
      _showError('링크 삭제 실패: $e');
    }
  }

  Future<void> _openLessonLink(Map<String, dynamic> link) async {
    final kind = (link['kind'] ?? '').toString();
    if (kind == 'resource') {
      try {
        final rf = ResourceFile.fromMap({
          'id': link['id'],
          'curriculum_node_id': link['curriculum_node_id'],
          'title': link['resource_title'],
          'filename': link['resource_filename'],
          'mime_type': null,
          'size_bytes': null,
          'storage_bucket': link['resource_bucket'] ?? _defaultResourceBucket,
          'storage_path': link['resource_path'] ?? '',
          'created_at': link['created_at'],
        });
        final url = await _res.signedUrl(rf);
        await _file.openUrl(url);
      } catch (e) {
        _showError('리소스 열기 실패: $e');
      }
      return;
    }

    // kind == 'node' → 브라우저/스튜디오로 이동 시도, 실패 시 ID 복사로 폴백
    final nodeId = (link['curriculum_node_id'] ?? '').toString();
    if (nodeId.isEmpty) {
      _showError('노드 정보를 찾을 수 없습니다.');
      return;
    }
    try {
      // TODO: CurriculumService 쪽에 실제 구현 필요
      // - macOS/Windows 데스크탑: 내부 라우트 또는 외부 브라우저 딥링크
      // - 구현 없으면 아래 catch로 폴백
      await _curr.openInBrowser(nodeId);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: nodeId));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('노드 ID를 클립보드에 복사했습니다.')));
    }
  }

  // ===== 노드/리소스 선택 다이얼로그 =====
  Future<String?> _pickNodeDialog() async {
    final all = await _curr.listNodes(); // 전체 → 클라 필터
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctl = TextEditingController();
        List<Map<String, dynamic>> filtered = all;

        return StatefulBuilder(
          builder: (ctx, setSt) {
            void apply() {
              final q = ctl.text.trim().toLowerCase();
              filtered = q.isEmpty
                  ? all
                  : all.where((m) {
                      final title = (m['title'] ?? '').toString().toLowerCase();
                      final id = (m['id'] ?? '').toString().toLowerCase();
                      return title.contains(q) || id.contains(q);
                    }).toList();
              setSt(() {}); // ← 안전한 리빌드
            }

            return AlertDialog(
              title: const Text('노드 선택'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: ctl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '제목/ID 검색…',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => apply(),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 320,
                      child: Scrollbar(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final m = filtered[i];
                            final isFile = (m['type'] ?? '') == 'file';
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isFile ? Icons.insert_drive_file : Icons.folder,
                              ),
                              title: Text((m['title'] ?? '').toString()),
                              subtitle: Text(
                                (m['id'] ?? '').toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => Navigator.pop(
                                ctx,
                                (m['id'] ?? '').toString(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('닫기'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _pickResourceDialog(String nodeId) async {
    final files = await _res.listByNode(nodeId);
    if (!mounted) return null;
    if (files.isEmpty) {
      _showError('이 노드에 등록된 리소스가 없습니다.');
      return null;
    }
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('리소스 선택'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: Scrollbar(
            child: ListView.builder(
              itemCount: files.length,
              itemBuilder: (_, i) {
                final f = files[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.link),
                  title: Text(f.title ?? f.filename),
                  subtitle: Text('${f.storageBucket}/${f.storagePath}'),
                  onTap: () => Navigator.pop(ctx, {
                    'title': f.title,
                    'filename': f.filename,
                    'bucket': f.storageBucket,
                    'path': f.storagePath,
                  }),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  // ===== 링크 액션 =====
  Future<void> _linkCurriculumNode() async {
    final nodeId = await _pickNodeDialog();
    if (nodeId == null || nodeId.trim().isEmpty) return;

    final ok = await _links.sendNodeToTodayLesson(
      studentId: _studentId,
      nodeId: nodeId.trim(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '노드를 오늘 레슨에 링크했어요.' : '링크 실패: 서버 RPC 미구성 또는 권한 오류'),
      ),
    );
    if (ok) unawaited(_reloadLessonLinks());
  }

  Future<void> _linkCurriculumResource() async {
    final nodeId = await _pickNodeDialog();
    if (nodeId == null || nodeId.trim().isEmpty) return;

    final picked = await _pickResourceDialog(nodeId);
    if (picked == null) return;

    final rf = ResourceFile.fromMap({
      'id': '',
      'curriculum_node_id': nodeId,
      'title': picked['title'],
      'filename': picked['filename'],
      'mime_type': null,
      'size_bytes': null,
      'storage_bucket': picked['bucket'] ?? _defaultResourceBucket,
      'storage_path': picked['path'],
      'created_at': DateTime.now().toIso8601String(),
    });

    final ok = await _links.sendResourceToTodayLesson(
      studentId: _studentId,
      resource: rf,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '리소스를 오늘 레슨에 링크했어요.' : '링크 실패: 서버 RPC 미구성 또는 권한 오류'),
      ),
    );
    if (ok) unawaited(_reloadLessonLinks());
  }

  // ===== 기타 =====
  void _toggleKeyword(String value) {
    if (_selectedKeywords.contains(value)) {
      _selectedKeywords.remove(value);
    } else {
      _selectedKeywords.add(value);
    }
    if (mounted) setState(() {});
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
      if (mounted) setState(() {});
      _scheduleSave();
    } catch (e) {
      _showError('첨부 업로드 실패: $e');
    }
  }

  Future<void> _handleRemoveAttachment(int index) async {
    try {
      final removed = _attachments.removeAt(index);
      if (mounted) setState(() {});
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
          // ===== 링크 액션바 =====
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _linkCurriculumNode,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('노드 선택해서 링크'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _linkCurriculumResource,
                    icon: const Icon(Icons.link),
                    label: const Text('리소스 선택해서 링크'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _reloadLessonLinks(ensure: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('링크 새로고침'),
                  ),
                  Text(
                    '스튜디오/브라우저에서 만든 콘텐츠를 바로 연결하세요.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

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
            title: '🔗 오늘 레슨 링크',
            section: _LocalSection.lessonLinks,
            child: _buildLessonLinksList(),
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
                        await _file.openUrl(url);
                      } catch (e) {
                        _showError('링크 열기 실패: $e');
                      }
                      _scheduleSave();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final url = _youtubeCtl.text.trim();
                    if (url.isEmpty) return;
                    try {
                      await _file.openUrl(url);
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

  Widget _buildLessonLinksList() {
    if (_loadingLinks) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_todayLinks.isEmpty) {
      return Text('아직 링크가 없습니다.', style: Theme.of(context).textTheme.bodySmall);
    }

    String titleOf(Map m) {
      final kind = (m['kind'] ?? '').toString();
      if (kind == 'node') {
        final t = (m['node_title'] ?? '').toString().trim();
        return t.isEmpty ? '(제목 없음)' : t;
      } else {
        final t = (m['resource_title'] ?? '').toString().trim();
        if (t.isNotEmpty) return t;
        return (m['resource_filename'] ?? '리소스').toString();
      }
    }

    return Column(
      children: _todayLinks.map((m) {
        final kind = (m['kind'] ?? '').toString();
        final isNode = kind == 'node';

        return ListTile(
          dense: true,
          leading: Icon(isNode ? Icons.folder : Icons.insert_drive_file),
          title: Text(titleOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
          // 서브텍스트 과감히 제거(필요시 … 메뉴에 '정보 복사')
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: isNode ? '브라우저에서 열기' : '파일 열기',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => _openLessonLink(m),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final id = (m['id'] ?? '').toString();
                  switch (v) {
                    case 'copy_id':
                      final text = isNode
                          ? (m['curriculum_node_id'] ?? '').toString()
                          : '${m['resource_bucket'] ?? _defaultResourceBucket}/${m['resource_path'] ?? ''}';
                      await Clipboard.setData(ClipboardData(text: text));
                      if (!mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('복사했습니다.')));
                      break;
                    case 'delete':
                      if (id.isEmpty) return;
                      _removeLessonLink(id);
                      break;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'copy_id',
                    child: Text(isNode ? '노드 ID 복사' : '경로 복사'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'delete', child: Text('삭제')),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

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
                  try {
                    final items = await _keyword.fetchItemsByCategory(v);
                    if (!mounted) return;
                    setState(() {
                      _items = items;
                    });
                    await _applyKeywordSearch();
                  } catch (e) {
                    if (!mounted) return;
                    _showError('키워드 불러오기 실패: $e');
                  }
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
            FilledButton.icon(
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
