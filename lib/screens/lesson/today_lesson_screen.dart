// lib/screens/lesson/today_lesson_screen.dart
// v1.68-ux3+auto+bsel | 오늘 수업 자동 복습 프리필 + 링크 클릭열기 + 선택/일괄삭제
// - '오늘 레슨 링크' 섹션:
//   1) '파일 열기' 버튼 제거, 버튼 제외한 박스(ListTile 영역) 클릭 시 열기
//   2) 메뉴 표시 버튼(⋮) 유지 (복사/노드열기/삭제 등)
//   3) 선택 모드(체크박스) 추가: 선택/해제, 모두 선택, 선택 삭제(N), 전체 삭제

import 'dart:async' show Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../ui/components/drop_upload_area.dart';
import '../../ui/components/save_status_indicator.dart';

import '../../services/lesson_service.dart';
import '../../services/keyword_service.dart';
import '../../services/file_service.dart';
import '../../services/log_service.dart';

import '../../services/lesson_links_service.dart';
import '../../services/curriculum_service.dart';
import '../../services/resource_service.dart';
import '../../models/resource.dart';
import '../../services/xsc_sync_service.dart';
import '../../services/student_service.dart';

class TodayLessonScreen extends StatefulWidget {
  const TodayLessonScreen({super.key});
  @override
  State<TodayLessonScreen> createState() => _TodayLessonScreenState();
}

class _TodayLessonScreenState extends State<TodayLessonScreen> {
  final LessonService _service = LessonService();
  final KeywordService _keyword = KeywordService();
  final FileService _file = FileService();

  final LessonLinksService _links = LessonLinksService();
  final CurriculumService _curr = CurriculumService();
  final ResourceService _res = ResourceService();
  String get _defaultResourceBucket => ResourceService.bucket;

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();
  final _keywordSearchCtl = TextEditingController();

  // 스크롤/패널 제어
  final ScrollController _scrollCtl = ScrollController();
  final GlobalKey _uploadPanelKey = GlobalKey();

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

  // 자동 복습 1회 수행 보호
  bool _autoPrefillTried = false;

  // 오늘 날짜 (YYYY-MM-DD)
  late String _todayDateStr;

  // 키워드 (DB) 상태
  List<String> _categories = const [];
  String? _selectedCategory;
  List<KeywordItem> _items = const [];
  List<KeywordItem> _filteredItems = const [];
  final Set<String> _selectedKeywords = {};

  // 레거시 첨부 – 데이터는 유지(저장/호환), UI는 제거됨
  final List<Map<String, dynamic>> _attachments = [];

  // 오늘 레슨 링크
  List<Map<String, dynamic>> _todayLinks = const [];
  bool _loadingLinks = false;

  bool _initialized = false;
  bool _loadingKeywords = false;

  // 상단 업로드 패널 표시 여부
  bool _showUploadPanel = false;

  // 링크 hover 상태
  String? _hoveredLinkId;

  // ===== 선택 모드 / 일괄 삭제 상태 =====
  bool _selectMode = false;
  final Set<String> _selectedLinkIds = <String>{};

  bool get _isDesktop =>
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux) && !kIsWeb;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    // 인자 파싱
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
    // ★ 학생 모드 첫 진입 시: 학생-토큰 연결 보장
    await StudentService().attachMeToStudent(_studentId);

    if ((initialLessonId ?? '').isNotEmpty) {
      try {
        final row = await _service.getById(initialLessonId!);
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

    // 히스토리에서 넘어온 명시 복습
    if (((_fromHistoryId ?? '')).isNotEmpty) {
      await _prefillFromHistory(_fromHistoryId!);
    }

    await _loadKeywordData();

    // 오늘 링크 로드
    await _reloadLessonLinks(ensure: true);

    // 자동 복습: 오늘 링크 비어 있고(fromHistoryId 없음)일 때 1회만
    if ((_fromHistoryId ?? '').isEmpty) {
      await _maybeAutoPrefillFromLatestPast();
    }
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
      if (((_lessonId ?? '')).isNotEmpty) {
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
          if (((_teacherId ?? '')).isNotEmpty) 'teacher_id': _teacherId,
          'date': _todayDateStr,
          'subject': '',
          'memo': '',
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

  // ===== 자동 복습 본체 =====
  Future<void> _maybeAutoPrefillFromLatestPast() async {
    if (_autoPrefillTried) return;
    _autoPrefillTried = true;

    try {
      // 오늘 링크가 이미 있으면 자동 복습 생략
      if (_todayLinks.isNotEmpty) return;

      // 가장 최근 과거 레슨 1건
      final now = DateTime.now();
      final startToday = DateTime(now.year, now.month, now.day);
      final to = startToday.subtract(const Duration(seconds: 1));

      final pastList = await _service.listByStudent(
        _studentId,
        to: to,
        limit: 1,
        asc: false,
      );
      if (pastList.isEmpty) return; // 과거 수업 없음 → 그대로 빈 흐름 유지

      final latest = Map<String, dynamic>.from(pastList.first);
      final historyId = (latest['id'] ?? '').toString();
      if (historyId.isEmpty) return;

      // 1) 텍스트류 프리필
      await _prefillFromHistory(historyId);

      // 2) 연결된 파일/첨부를 오늘 레슨에 담기
      final links = await _links.listByLesson(historyId);
      final List attachmentsRaw = (latest['attachments'] is List)
          ? latest['attachments'] as List
          : [];

      Map<String, dynamic> _normalizeAttachment(dynamic a) {
        if (a is Map) return Map<String, dynamic>.from(a);
        final s = a?.toString() ?? '';
        return <String, dynamic>{
          'url': s,
          'path': s,
          'name': s.split('/').last,
        };
      }

      final atts = attachmentsRaw.map(_normalizeAttachment).toList();

      final r1 = await _links.addResourceLinkMapsToToday(
        studentId: _studentId,
        linkRows: links,
      );
      final r2 = await _links.addAttachmentsToTodayLesson(
        studentId: _studentId,
        attachments: atts,
      );

      final added = r1.added + r2.added;
      final dup = r1.duplicated + r2.duplicated;
      final failed = r1.failed + r2.failed;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ $added개 추가됨 (중복 $dup, 실패 $failed) — 지난 수업을 자동으로 불러왔어요.',
            ),
          ),
        );
      }

      // 3) 오늘 링크 갱신
      await _reloadLessonLinks(ensure: true);
    } catch (e) {
      _showError('자동 복습 적용 중 오류: $e');
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
    if (((_lessonId ?? '')).isEmpty) return;
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
        if (((_teacherId ?? '')).isNotEmpty) 'teacher_id': _teacherId,
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

  Future<void> _reloadLessonLinks({bool ensure = false}) async {
    if (mounted) setState(() => _loadingLinks = true);
    try {
      final list = await _links.listTodayByStudent(_studentId, ensure: ensure);
      if (!mounted) return;
      setState(() {
        _todayLinks = list;
        // 선택 모드 중에 목록이 갱신되면 선택 상태 정리
        _selectedLinkIds.removeWhere(
          (id) => !_todayLinks.any((m) => (m['id'] ?? '').toString() == id),
        );
      });
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

  Future<void> _removeLessonLinksBulk(Iterable<String> ids) async {
    int ok = 0, fail = 0;
    for (final id in ids) {
      try {
        final r = await _links.deleteById(id, studentId: _studentId);
        if (r)
          ok++;
        else
          fail++;
      } catch (_) {
        fail++;
      }
    }
    await _reloadLessonLinks();
    _selectedLinkIds.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('삭제 완료: 성공 $ok · 실패 $fail')));
  }

  Future<void> _confirmAndRemoveAll() async {
    if (_todayLinks.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('전체 삭제'),
        content: const Text('오늘 레슨 링크를 모두 삭제할까요? 이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final ids = _todayLinks
        .map((m) => (m['id'] ?? '').toString())
        .where((s) => s.isNotEmpty);
    await _removeLessonLinksBulk(ids);
  }

  Future<void> _linkCurriculumResourceAssigned() async {
    final pickedList = await _pickAssignedResourceDialog();
    if (pickedList == null || pickedList.isEmpty) return;

    int ok = 0, dup = 0, fail = 0;
    for (final picked in pickedList) {
      final rmap = {
        'resource_bucket': picked['bucket'] ?? _defaultResourceBucket,
        'resource_path': picked['path'],
        'resource_filename': picked['filename'],
        'resource_title': picked['title'],
        'curriculum_node_id': picked['node_id'],
        'mime_type': picked['mime_type'],
        'size_bytes': picked['size_bytes'],
        'created_at': DateTime.now().toIso8601String(),
      };
      final res = await _links.addResourceLinkMapToToday(
        studentId: _studentId,
        linkRow: rmap,
      );
      ok += res.added;
      dup += res.duplicated;
      fail += res.failed;
    }

    if (!mounted) return;
    final msg = (fail == 0 && dup == 0)
        ? '리소스 $ok개를 오늘 레슨에 링크했어요.'
        : '결과: 성공 $ok · 중복 $dup · 실패 $fail';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _reloadLessonLinks(ensure: true);
  }

  Future<List<Map<String, dynamic>>?> _pickAssignedResourceDialog() async {
    // 1) 학생에게 배정된 리소스 목록
    final assigned = await _curr.fetchAssignedResourcesForStudent(_studentId);
    if (!mounted) return null;
    if (assigned.isEmpty) {
      _showError('배정된 리소스가 없습니다.');
      return null;
    }

    // 2) curriculum_nodes 트리에서 node_id -> 루트 타이틀 맵 생성 (널 안전)
    final nodesRaw = await _curr.listNodes(); // List<Map>
    final Map<String, Map<String, dynamic>> byId = {
      for (final m in nodesRaw)
        if ((m['id'] ?? '').toString().isNotEmpty)
          (m['id'] as Object).toString(): Map<String, dynamic>.from(m),
    };

    String rootTitleOf(String nodeId) {
      if (nodeId.isEmpty) return '(루트 미지정)';
      var cur = byId[nodeId];
      int guard = 0;
      while (cur != null &&
          cur['parent_id'] != null &&
          ((cur['parent_id'] ?? '').toString().isNotEmpty) &&
          guard < 128) {
        final pid = (cur['parent_id'] ?? '').toString();
        cur = byId[pid];
        guard++;
      }
      final t = (cur != null ? (cur['title'] ?? '').toString().trim() : '');
      return t.isEmpty ? '(루트 미지정)' : t;
    }

    // assigned 안의 node_id들만 미리 계산
    final Map<String, String> nodeRootTitleMap = {};
    for (final r in assigned) {
      final nid = (r['curriculum_node_id'] ?? '').toString();
      if (nid.isEmpty || nodeRootTitleMap.containsKey(nid)) continue;
      nodeRootTitleMap[nid] = rootTitleOf(nid);
    }

    // 3) 다이얼로그 표시
    return showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _AssignedResourcesPickerDialog(
        assigned: assigned
            .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
            .toList(),
        defaultBucket: _defaultResourceBucket,
        nodeRootTitleMap: nodeRootTitleMap, // ← 루트 타이틀 맵 주입
        studentId: _studentId,
        curr: _curr,
      ),
    );
  }

  // ===== 링크/첨부 열기 =====
  Future<void> _openLessonLink(Map<String, dynamic> link) async {
    final kind = (link['kind'] ?? '').toString();

    if (kind == 'resource') {
      try {
        await _links.openFromLessonLink(
          LessonLinkItem(
            id: (link['id'] ?? '').toString(),
            lessonId: (link['lesson_id'] ?? _lessonId ?? '').toString(),
            title: (link['resource_title'] ?? '').toString().isNotEmpty
                ? link['resource_title'].toString()
                : (link['resource_filename'] ?? 'resource').toString(),
            resourceBucket: (link['resource_bucket'] ?? _defaultResourceBucket)
                .toString(),
            resourcePath: (link['resource_path'] ?? '').toString(),
            resourceFilename: (link['resource_filename'] ?? 'resource')
                .toString(),
            createdAt:
                DateTime.tryParse((link['created_at'] ?? '').toString()) ??
                DateTime.now(),
          ),
          studentId: _studentId,
        );
      } catch (e) {
        _showError('리소스 열기 실패: $e');
      }
      return;
    }

    final nodeId = (link['curriculum_node_id'] ?? '').toString();
    if (nodeId.isEmpty) {
      _showError('노드 정보를 찾을 수 없습니다.');
      return;
    }
    try {
      await _curr.openInBrowser(nodeId);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: nodeId));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('노드 ID를 클립보드에 복사했습니다.')));
    }
  }

  Future<void> _openLatestXsc(Map<String, dynamic> link) async {
    try {
      await XscSyncService().openFromLessonLinkMap(
        link: link,
        studentId: _studentId,
      );
    } catch (e) {
      _showError('xsc 열기 실패: $e');
    }
  }

  Future<void> _openOriginalAudio(Map<String, dynamic> link) async {
    try {
      final bucket = (link['resource_bucket'] ?? _defaultResourceBucket)
          .toString();
      final storagePath = (link['resource_path'] ?? '').toString(); // 그대로
      final displayName = (link['resource_filename'] ?? 'resource').toString();

      final rf = ResourceFile.fromMap({
        'id': link['id'],
        'curriculum_node_id': link['curriculum_node_id'],
        'title': link['resource_title'],
        'filename': displayName,
        'mime_type': null,
        'size_bytes': null,
        'storage_bucket': bucket,
        'storage_path': storagePath,
        'created_at': link['created_at'],
      });

      final url = await _res.signedUrl(rf);
      await _file.saveUrlToWorkspaceAndOpen(
        studentId: _studentId,
        filename: rf.filename,
        url: url,
        bucket: bucket, // ← 고유화에 사용
        storagePath: storagePath, // ← 고유화에 사용
      );
    } catch (e) {
      _showError('원본 미디어 열기 실패: $e');
    }
  }

  void _toggleKeyword(String value) {
    if (_selectedKeywords.contains(value)) {
      _selectedKeywords.remove(value);
    } else {
      _selectedKeywords.add(value);
    }
    if (mounted) setState(() {});
    _scheduleSave();
  }

  // === 업로드 패널 토글 + 스크롤 보장 ===
  void _toggleUploadPanel() {
    setState(() => _showUploadPanel = !_showUploadPanel);

    if (_showUploadPanel) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ctx = _uploadPanelKey.currentContext;
        if (ctx != null) {
          await Scrollable.ensureVisible(
            ctx,
            alignment: 0.2,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  // === 실제 파일 선택(Finder/탐색기) → 리소스 업로드 → 링크 갱신 ===
  Future<void> _pickUpload() async {
    if (!_isDesktop) return;
    try {
      final resources = await _file.pickAndAttachAsResourcesForTodayLesson(
        studentId: _studentId,
      );
      if (resources.isEmpty) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('리소스 ${resources.length}개를 링크했어요.')),
      );

      await _reloadLessonLinks(ensure: true);
    } catch (e) {
      _showError('업로드 실패: $e');
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

  // ===== 선택 모드 토글/유틸 =====
  void _enterSelectMode() {
    setState(() {
      _selectMode = true;
      _selectedLinkIds.clear();
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedLinkIds.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedLinkIds.length == _todayLinks.length) {
        _selectedLinkIds.clear();
      } else {
        _selectedLinkIds
          ..clear()
          ..addAll(
            _todayLinks
                .map((m) => (m['id'] ?? '').toString())
                .where((s) => s.isNotEmpty),
          );
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _kwSearchDebounce?.cancel();
    _subjectCtl.dispose();
    _memoCtl.dispose();
    _youtubeCtl.dispose();
    _keywordSearchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('오늘 수업')),
      body: SingleChildScrollView(
        controller: _scrollCtl,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 1) 빠른 실행 바: 링크/업로드/유튜브 =====
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _linkCurriculumResourceAssigned,
                          icon: const Icon(Icons.link),
                          label: const Text('리소스 링크 추가'),
                        ),
                        // 업로드 버튼은 패널 열기/닫기만 수행
                        FilledButton.icon(
                          onPressed: _toggleUploadPanel,
                          icon: Icon(
                            _showUploadPanel
                                ? Icons.expand_less
                                : Icons.expand_more,
                          ),
                          label: const Text('업로드'),
                        ),
                      ],
                    ),

                    // 업로드 확장 패널 (실제 업로드 UI)
                    AnimatedCrossFade(
                      key: _uploadPanelKey,
                      crossFadeState: _showUploadPanel
                          ? CrossFadeState.showFirst
                          : CrossFadeState.showSecond,
                      duration: const Duration(milliseconds: 200),
                      firstChild: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '파일을 선택하거나 드래그로 업로드하면 공용 리소스로 저장되고, 오늘 레슨에 자동 링크됩니다.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            if (_isDesktop)
                              Row(
                                children: [
                                  FilledButton.icon(
                                    onPressed: _pickUpload,
                                    icon: const Icon(Icons.folder_open),
                                    label: const Text('파일 선택'),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '(또는 아래 영역에 드래그)',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              )
                            else
                              Text(
                                '⚠️ 모바일/Web에서는 업로드/드래그 기능이 제한됩니다. 데스크탑에서 사용해주세요.',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.orange),
                              ),
                            const SizedBox(height: 8),
                            if (_isDesktop)
                              DropUploadArea(
                                studentId: _studentId,
                                dateStr: _todayDateStr,
                                onUploaded: (List<ResourceFile> list) {
                                  if (list.isNotEmpty) {
                                    unawaited(
                                      _reloadLessonLinks(
                                        ensure: true,
                                      ).catchError((e) {
                                        if (!mounted) return;
                                        _showError('링크 목록 새로고침 실패: $e');
                                      }),
                                    );
                                  }
                                  if (!mounted) return;
                                  setState(() {}); // 링크 섹션 갱신
                                  _scheduleSave(); // 오늘 수업 row 저장
                                },
                                onError: (err) =>
                                    _showError('드래그 업로드 실패: $err'),
                              ),
                          ],
                        ),
                      ),
                      secondChild: const SizedBox(height: 0),
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _youtubeCtl,
                            decoration: const InputDecoration(
                              hintText: '▶️ 유튜브 URL을 붙여넣고 엔터로 열기',
                              border: OutlineInputBorder(),
                              isDense: true,
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
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '배정된 리소스 링크 추가 또는 업로드로 오늘 레슨 자료를 빠르게 준비하세요.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ===== 2) 오늘 레슨 링크(평면 리스트) =====
            Row(
              children: [
                Text('오늘 레슨 링크', style: _sectionH1(context)),
                const SizedBox(width: 8),
                if (!_selectMode && _todayLinks.isNotEmpty)
                  TextButton(
                    onPressed: _enterSelectMode,
                    child: const Text('선택'),
                  ),
                if (_selectMode) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _toggleSelectAll,
                    child: Text(
                      _selectedLinkIds.length == _todayLinks.length
                          ? '모두 해제'
                          : '모두 선택',
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _selectedLinkIds.isEmpty
                        ? null
                        : () => _removeLessonLinksBulk(_selectedLinkIds),
                    child: Text(
                      _selectedLinkIds.isEmpty
                          ? '선택 삭제'
                          : '선택 삭제(${_selectedLinkIds.length})',
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _exitSelectMode,
                    child: const Text('취소'),
                  ),
                ],
                const Spacer(),
                // 섹션 더보기(전체 삭제)
                if (_todayLinks.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: '섹션 메뉴',
                    onSelected: (v) async {
                      if (v == 'delete_all') {
                        await _confirmAndRemoveAll();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete_all', child: Text('전체 삭제')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 6),
            _buildLessonLinksListPlain(),

            const SizedBox(height: 16),

            // ===== 3) 주제 =====
            Text('주제', style: _sectionH1(context)),
            const SizedBox(height: 6),
            TextField(
              controller: _subjectCtl,
              decoration: const InputDecoration(
                hintText: '예: 코드 전환 + 다운업 스트로크',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),

            const SizedBox(height: 16),

            // ===== 4) 키워드 =====
            Text('키워드', style: _sectionH1(context)),
            const SizedBox(height: 8),
            _buildKeywordControls(),
            const SizedBox(height: 8),
            _buildKeywordSearchBox(),
            const SizedBox(height: 8),
            _buildKeywordChips(),

            const SizedBox(height: 16),

            // ===== 5) 메모 (10줄) =====
            Text('수업 메모', style: _sectionH1(context)),
            const SizedBox(height: 6),
            TextField(
              controller: _memoCtl,
              decoration: const InputDecoration(
                hintText: '수업 중 메모를 기록하세요',
                border: OutlineInputBorder(),
              ),
              maxLines: 10, // 10줄 유지
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SaveStatusIndicator(
            status: _status,
            lastSavedAt: _lastSavedAt,
          ),
        ),
      ),
    );
  }

  // ===== 공통 UI 빌더 =====

  TextStyle _sectionH1(BuildContext ctx) =>
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

  // 오늘 레슨 링크 평면 리스트
  Widget _buildLessonLinksListPlain() {
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

    bool hasXscMeta(Map m) =>
        (m['xsc_updated_at'] != null &&
            m['xsc_updated_at'].toString().isNotEmpty) ||
        (m['xsc_storage_path'] != null &&
            m['xsc_storage_path'].toString().isNotEmpty);

    String? xscStamp(Map m) {
      final v = m['xsc_updated_at']?.toString();
      if (v == null || v.isEmpty) return null;
      return _fmtLocalStamp(v) ?? v;
    }

    bool isAudioLink(Map m) {
      final name = (m['resource_filename'] ?? '').toString().toLowerCase();
      return name.endsWith('.mp3') ||
          name.endsWith('.m4a') ||
          name.endsWith('.wav') ||
          name.endsWith('.aif') ||
          name.endsWith('.aiff') ||
          name.endsWith('.mp4') ||
          name.endsWith('.mov');
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: _todayLinks.map((m) {
          final id = (m['id'] ?? '').toString();
          final kind = (m['kind'] ?? '').toString();
          final isNode = kind == 'node';
          final showXsc = !isNode && hasXscMeta(m);
          final isAudio = !isNode && isAudioLink(m);

          final isHover = _hoveredLinkId == id;
          final base = Theme.of(context).colorScheme.surfaceContainerHighest;
          final hoverBg = base.withValues(alpha: 0.22);

          final bucket = (m['resource_bucket'] ?? _defaultResourceBucket)
              .toString();
          final path = (m['resource_path'] ?? '').toString();
          final filename = (m['resource_filename'] ?? '').toString();
          final tip = isNode
              ? '노드: ${(m['curriculum_node_id'] ?? '').toString()}'
              : '$bucket/$path/$filename';

          final checked = _selectedLinkIds.contains(id);

          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoveredLinkId = id),
            onExit: (_) => setState(() => _hoveredLinkId = null),
            child: Tooltip(
              message: tip,
              waitDuration: const Duration(milliseconds: 300),
              child: Container(
                decoration: BoxDecoration(
                  color: isHover ? hoverBg : null,
                  borderRadius: BorderRadius.circular(12),
                  border: isHover
                      ? Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        )
                      : null,
                ),
                child: ListTile(
                  dense: true,
                  leading: _selectMode
                      ? Checkbox(
                          value: checked,
                          onChanged: (_) {
                            setState(() {
                              if (checked) {
                                _selectedLinkIds.remove(id);
                              } else {
                                _selectedLinkIds.add(id);
                              }
                            });
                          },
                        )
                      : Icon(isNode ? Icons.folder : Icons.insert_drive_file),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          titleOf(m),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (showXsc)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Tooltip(
                            message: xscStamp(m) != null
                                ? '최근 저장: ${xscStamp(m)!}'
                                : '학생별 xsc 연결됨',
                            child: const Chip(
                              label: Text('최근 저장본'),
                              padding: EdgeInsets.zero,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showXsc)
                        IconButton(
                          tooltip: 'xsc(최신) 열기',
                          icon: const Icon(Icons.music_note),
                          onPressed: () => _openLatestXsc(m),
                        ),
                      // ⛔️ '파일 열기' 버튼 제거됨 — 박스 클릭으로 대체
                      PopupMenuButton<String>(
                        onSelected: (v) async {
                          switch (v) {
                            case 'copy_id':
                              final text = isNode
                                  ? (m['curriculum_node_id'] ?? '').toString()
                                  : '${m['resource_bucket'] ?? _defaultResourceBucket}/${m['resource_path'] ?? ''}';
                              await Clipboard.setData(
                                ClipboardData(text: text),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('경로 복사됨')),
                              );
                              break;

                            case 'copy_filename':
                              final raw = (m['resource_filename'] ?? '')
                                  .toString();
                              final withoutExt = raw.contains('.')
                                  ? raw.substring(0, raw.lastIndexOf('.'))
                                  : raw;
                              await Clipboard.setData(
                                ClipboardData(text: withoutExt),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('파일명 복사됨: $withoutExt')),
                              );
                              break;

                            case 'open_node':
                              final nodeId = (m['curriculum_node_id'] ?? '')
                                  .toString();
                              if (nodeId.isEmpty) break;
                              try {
                                await _curr.openInBrowser(nodeId);
                              } catch (_) {
                                await Clipboard.setData(
                                  ClipboardData(text: nodeId),
                                );
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('노드 ID를 복사했습니다.'),
                                  ),
                                );
                              }
                              break;

                            case 'delete':
                              final lid = (m['id'] ?? '').toString();
                              if (lid.isEmpty) return;
                              _removeLessonLink(lid);
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'copy_id',
                            child: Text(isNode ? '노드 ID 복사' : '경로 복사'),
                          ),
                          if (!isNode)
                            const PopupMenuItem(
                              value: 'copy_filename',
                              child: Text('파일명 복사'),
                            ),
                          if (isNode)
                            const PopupMenuItem(
                              value: 'open_node',
                              child: Text('커리큘럼에서 열기'),
                            ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('삭제'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // ✅ 버튼 제외한 박스 클릭 시 열기(선택 모드면 선택 토글)
                  onTap: () {
                    if (_selectMode) {
                      setState(() {
                        if (checked) {
                          _selectedLinkIds.remove(id);
                        } else {
                          _selectedLinkIds.add(id);
                        }
                      });
                      return;
                    }
                    _openLessonLink(m);
                  },
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // === 키워드 섹션 UI ===
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
                const SnackBar(content: Text('키워드 캐시 초기화 및 재로딩 완료')),
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

  String? _fmtLocalStamp(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

// ======================= 배정 리소스 다중 선택 다이얼로그 (패치본) =======================

class _AssignedResourcesPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> assigned;
  final String defaultBucket;
  final Map<String, String>? nodeRootTitleMap; // ← 옵션: node_id -> root_title
  final String studentId;
  final CurriculumService curr;

  const _AssignedResourcesPickerDialog({
    required this.assigned,
    required this.defaultBucket,
    this.nodeRootTitleMap,
    required this.studentId,
    required this.curr,
  });

  @override
  State<_AssignedResourcesPickerDialog> createState() =>
      _AssignedResourcesPickerDialogState();
}

class _AssignedResourcesPickerDialogState
    extends State<_AssignedResourcesPickerDialog> {
  final _queryCtl = TextEditingController();

  // 선택 상태 (key: bucket::path::filename)
  final Map<String, Map<String, dynamic>> _selected = {};

  bool _selectAll = false;

  // 루트 카테고리 목록/선택 상태
  late final List<String> _roots;
  String _selectedRoot = '전체';

  // 서버 검색 상태
  List<Map<String, dynamic>> _list = const []; // 현재 표시 리스트(초기: assigned)
  Timer? _searchDebounce;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _roots = _collectRoots(widget.assigned);
    _list = widget.assigned;
    _queryCtl.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(
        const Duration(milliseconds: 250),
        _runSearch,
      ); // 서버검색 디바운스
      if (mounted) setState(() {}); // suffixIcon 즉시 갱신용
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _queryCtl.dispose();
    super.dispose();
  }

  String _basename(String s) {
    final i = s.lastIndexOf('.');
    return (i > 0) ? s.substring(0, i) : s;
  }

  String _normKo(String s) {
    final nfc = s.isEmpty ? s : unorm.nfc(s);
    return nfc.toLowerCase().replaceAll(
      RegExp(r'[\s\-\_\.\(\)\[\]\{\},/]+'),
      '',
    );
  }

  String _lastSegment(String s) {
    final t = s.split('/').where((e) => e.isNotEmpty).toList();
    return t.isEmpty ? s : t.last;
  }

  Future<void> _runSearch() async {
    if (!mounted) return;
    final q = _queryCtl.text.trim();

    if (q.isEmpty) {
      setState(() {
        _loading = false;
        _list = widget.assigned;
      });
      return;
    }

    setState(() => _loading = true);

    final needle = _normKo(q);

    bool hit(Map<String, dynamic> r) {
      String v(String k) => (r[k] ?? '').toString();

      final filename = v('filename');
      final original = v('original_filename');
      final path = v('storage_path'); // 전체 경로
      final last = _lastSegment(path); // 마지막 세그먼트

      final bag =
          <String>[
                filename,
                _basename(filename), // 확장자 제거본
                original,
                _basename(original),
                path, // ✅ 전체 경로도 통째로 검색
                last,
                _basename(last),
                v('title'),
              ]
              .where((e) => e.trim().isNotEmpty)
              .map(_normKo) // ✅ NFC 정규화 + 소문자 + 구분자 제거
              .toList();

      return bag.any((h) => h.contains(needle));
    }

    setState(() {
      _list = widget.assigned.where(hit).toList();
      _loading = false;
    });
  }


  // ====== 루트 카테고리 추출 ======
  String _extractRoot(Map<String, dynamic> r) {
    String pickNonEmpty(List<String?> cands) {
      for (final c in cands) {
        final v = (c ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    // 1) 주입된 맵(node_id -> root_title)이 있으면 최우선 사용
    final nid = (r['curriculum_node_id'] ?? '').toString();
    if (nid.isNotEmpty &&
        (widget.nodeRootTitleMap?.containsKey(nid) ?? false)) {
      final t = widget.nodeRootTitleMap![nid] ?? '';
      if (t.trim().isNotEmpty) return t.trim();
    }

    // 2) 행 자체의 힌트 활용 (폴백)
    final nodeFull = (r['node_full_title'] ?? r['node_path'] ?? '').toString();
    final guessedFromChain = nodeFull.contains('/')
        ? nodeFull.split('/').first.trim()
        : (nodeFull.contains(' > ') ? nodeFull.split(' > ').first.trim() : '');

    final root = pickNonEmpty([
      r['root_title']?.toString(),
      r['node_root_title']?.toString(),
      r['category']?.toString(),
      guessedFromChain,
    ]);

    return root.isEmpty ? '(루트 미지정)' : root;
  }

  List<String> _collectRoots(List<Map<String, dynamic>> rows) {
    final s = <String>{};
    for (final r in rows) {
      s.add(_extractRoot(r));
    }
    final list = s.toList()..sort((a, b) => a.compareTo(b)); // 가나다/알파벳 정렬
    return ['전체', ...list];
  }

  // ====== 표시/검색용 원본 제목 ======
  String _originalTitleOf(Map<String, dynamic> r) {
    return (r['original_title'] ??
            r['original_filename'] ??
            r['filename'] ??
            r['title'] ??
            '')
        .toString()
        .trim();
  }

  // 목록 필터(루트/검색) + 정렬 + 중복 제거
  List<Map<String, dynamic>> _filtered() {
    final q = _queryCtl.text.trim();

    // 1) 파일만 통과: storage_path(or path) & filename 필요
    List<Map<String, dynamic>> base = _list.where((r) {
      final path = (r['storage_path'] ?? r['path'] ?? '').toString().trim();
      final filename = (r['filename'] ?? '').toString().trim();
      return path.isNotEmpty && filename.isNotEmpty;
    }).toList();

    // 2) 루트 카테고리 필터
    if (_selectedRoot != '전체') {
      base = base.where((r) => _extractRoot(r) == _selectedRoot).toList();
    }

    // 3) 추가 클라이언트 검색(서버검색 결과 위에 보조 필터)
    if (q.isNotEmpty) {
      final needle = _normKo(q);
      bool hit(Map<String, dynamic> r) {
        String v(String k) => (r[k] ?? '').toString();
        final filename = v('filename');
        final original = v('original_filename');
        final path = v('storage_path');
        final last = _lastSegment(path);

        final bag = <String>[
          filename,
          _basename(filename),
          original,
          _basename(original),
          last,
          _basename(last),
          v('title'),
        ].where((e) => e.trim().isNotEmpty).map(_normKo).toList();

        return bag.any((h) => h.contains(needle));
      }

      base = base.where(hit).toList();
    }


    // 4) 정렬 (가나다/알파벳): 원본 제목 → 없으면 타이틀/파일명
    base.sort((a, b) {
      String displayA = _originalTitleOf(a);
      if (displayA.isEmpty) {
        displayA = (a['title'] ?? a['filename'] ?? '').toString();
      }
      String displayB = _originalTitleOf(b);
      if (displayB.isEmpty) {
        displayB = (b['title'] ?? b['filename'] ?? '').toString();
      }
      return displayA.compareTo(displayB);
    });

    // 5) 중복 제거: bucket::path::filename
    final seen = <String>{};
    final items = <Map<String, dynamic>>[];
    for (final r in base) {
      final bucket = (r['storage_bucket'] ?? widget.defaultBucket).toString();
      final path = (r['storage_path'] ?? r['path'] ?? '').toString();
      final filename = (r['filename'] ?? '').toString();
      if (path.isEmpty || filename.isEmpty) continue;
      final key = '$bucket::$path::$filename';
      if (seen.add(key)) items.add(r);
    }

    return items;
  }

  String _keyOf(Map<String, dynamic> r) {
    final bucket = (r['storage_bucket'] ?? widget.defaultBucket).toString();
    final path = (r['storage_path'] ?? r['path'] ?? '').toString();
    final filename = (r['filename'] ?? '').toString();
    return '$bucket::$path::$filename';
  }

  void _toggleAll(List<Map<String, dynamic>> list, bool v) {
    setState(() {
      _selectAll = v;
      if (v) {
        for (final r in list) {
          final k = _keyOf(r);
          _selected[k] = {
            'title':
                (_originalTitleOf(r).isNotEmpty
                        ? _originalTitleOf(r)
                        : (r['title'] ?? r['filename'] ?? '리소스'))
                    .toString(),
            'filename': (r['filename'] ?? r['title'] ?? 'file').toString(),
            'bucket': (r['storage_bucket'] ?? widget.defaultBucket).toString(),
            'path': (r['storage_path'] ?? r['path'] ?? '').toString(),
            'node_id': r['curriculum_node_id'],
            'mime_type': r['mime_type'],
            'size_bytes': r['size_bytes'],
          };
        }
      } else {
        for (final r in list) {
          _selected.remove(_keyOf(r));
        }
      }
    });
  }

  void _toggleOne(Map<String, dynamic> r) {
    final path = (r['storage_path'] ?? r['path'] ?? '').toString().trim();
    final filename = (r['filename'] ?? '').toString().trim();
    if (path.isEmpty || filename.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('선택할 수 없는 항목입니다(카테고리/경로 없음).')),
      );
      return;
    }

    setState(() {
      final k = _keyOf(r);
      if (_selected.containsKey(k)) {
        _selected.remove(k);
      } else {
        _selected[k] = {
          'title':
              (_originalTitleOf(r).isNotEmpty
                      ? _originalTitleOf(r)
                      : (r['title'] ?? r['filename'] ?? '리소스'))
                  .toString(),
          'filename': filename,
          'bucket': (r['storage_bucket'] ?? widget.defaultBucket).toString(),
          'path': path,
          'node_id': r['curriculum_node_id'],
          'mime_type': r['mime_type'],
          'size_bytes': r['size_bytes'],
        };
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered();

    return AlertDialog(
      title: const Text('배정 리소스 선택'),
      content: SizedBox(
        width: 680,
        height: 520,
        child: Column(
          children: [
            // 루트 카테고리 + 검색
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '루트 카테고리',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedRoot,
                        items: _roots
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _selectedRoot = v);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _queryCtl,
                    decoration: InputDecoration(
                      hintText: '원본 제목/파일명/경로 검색… (원본 우선)',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _queryCtl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() {
                                _queryCtl.clear();
                              }),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}), // 즉시 UI 반영
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Switch(
                  value: _selectAll,
                  onChanged: (v) => _toggleAll(items, v),
                ),
                const Text('전체 선택'),
                const Spacer(),
                Text('선택: ${_selected.length}개'),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('표시할 리소스가 없습니다.'))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = items[i];

                        final displayTitle = (() {
                          final o = _originalTitleOf(r);
                          if (o.isNotEmpty) return o;
                          return (r['title'] ?? r['filename'] ?? '리소스')
                              .toString();
                        })();

                        final bucket =
                            (r['storage_bucket'] ?? widget.defaultBucket)
                                .toString();
                        final path = (r['storage_path'] ?? r['path'] ?? '')
                            .toString();
                        final filename = (r['filename'] ?? '').toString();
                        final root = _extractRoot(r);
                        final k = _keyOf(r);
                        final checked = _selected.containsKey(k);

                        return ListTile(
                          key: ValueKey(k),
                          dense: true,
                          leading: Checkbox(
                            value: checked,
                            onChanged: (_) => _toggleOne(r),
                          ),
                          title: Text(
                            displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '$root • $bucket/$path • $filename',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _toggleOne(r),
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
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.values.toList()),
          child: const Text('추가'),
        ),
      ],
    );
  }
}
