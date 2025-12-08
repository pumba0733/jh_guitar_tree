// v1.91-main-smp+notes-guard | 오늘 수업: SMP와 수업메모 양방향 동기화(단일 원본: Supabase lessons.memo)
// 변경점 요약:
// - _hydratingMemo 필드 추가: DB/프리필 등 "주입 중" 저장/발행 차단
// - _tryWireNotesSync(): pushNotes 발행 + notesStream 구독 (루프 방지)
// - _ensureTodayRow() 완료 직후 브릿지 연결
// - 나머지 동작(링크/업로드/키워드/리스트 등)은 기존과 동일

import 'dart:async' show Timer, unawaited, StreamSubscription;
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
import '../../services/student_service.dart'; // SMP
import '../../../packages/smart_media_player/smart_media_player_screen.dart';

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
  String get _defaultResourceBucket => ResourceService.bucket;

  final _subjectCtl = TextEditingController();
  final _memoCtl = TextEditingController();
  final _youtubeCtl = TextEditingController();
  final _keywordSearchCtl = TextEditingController();

  final ScrollController _scrollCtl = ScrollController();
  final GlobalKey _uploadPanelKey = GlobalKey();

  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  Timer? _debounce;
  Timer? _kwSearchDebounce;
  String? _lastSavedMemo;

  String? _lessonId;
  late String _studentId;
  String? _teacherId;
  String? _fromHistoryId;
  bool _autoPrefillTried = false;
  bool _openingLessonLink = false; // 🔒 링크/SMP 중복 오픈 가드

  late String _todayDateStr;

  // ignore: unused_field
  List<String> _categories = const [];
  // ignore: unused_field
  String? _selectedCategory;

  // services/keyword_service.dart의 KeywordItem 타입 사용
  // ignore: unused_field
  List<KeywordItem> _items = const [];
  // ignore: unused_field
  List<KeywordItem> _filteredItems = const [];

  final Set<String> _selectedKeywords = {};
  final List<Map<String, dynamic>> _attachments = [];
  List<Map<String, dynamic>> _todayLinks = const [];
  bool _loadingLinks = false;

  bool _initialized = false;
  // ignore: unused_field
  bool _loadingKeywords = false;
  bool _showUploadPanel = false;

  String? _hoveredLinkId;

  bool _selectMode = false;
  final Set<String> _selectedLinkIds = <String>{};

  // ⬇️ 추가: "주입 중 자동저장/발행 차단" 가드 & SMP ↔ TodayLesson 메모 동기화용
  bool _hydratingMemo = false; // ⬅️ DB/스트림 값 주입 중 표시
  StreamSubscription<String>? _notesSub; // ⬅️ XscSyncService 구독 핸들
  bool _memoChangeFromStream = false; // ⬅️ 루프 방지 플래그

  bool get _isDesktop =>
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux) && !kIsWeb;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final raw = ModalRoute.of(context)?.settings.arguments;
    final args = (raw is Map)
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    _studentId = (args['studentId'] as String?)?.trim() ?? '';
    _teacherId = (args['teacherId'] as String?)?.trim();
    _fromHistoryId = (args['fromHistoryId'] as String?)?.trim();
    final argLessonId = (args['lessonId'] as String?)?.trim();

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

    await _ensureTodayRow(); // lessons 행 보장
    _tryWireNotesSync(); // ⬅️ 여기서 바로 브릿지 연결

    if (((_fromHistoryId ?? '')).isNotEmpty) {
      await _prefillFromHistory(_fromHistoryId!);
    }

    await _loadKeywordData();
    await _reloadLessonLinks(ensure: true);

    if ((_fromHistoryId ?? '').isEmpty) {
      await _maybeAutoPrefillFromLatestPast();
    }
  }

  void _bindListeners() {
    _subjectCtl.addListener(_scheduleSave);

    // ⬇️ 메모 변경 → 저장 + SMP로 브로드캐스트(주입/루프 차단)
    Timer? _notesPushDebounce;

    _memoCtl.addListener(() {
      if (_hydratingMemo) return;
      _scheduleSave();
      if (_memoChangeFromStream) return;

      _notesPushDebounce?.cancel();
      _notesPushDebounce = Timer(const Duration(milliseconds: 150), () {
        try {
          XscSyncService.instance.pushNotes(_memoCtl.text);
        } catch (_) {}
      });
    });


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

  // ⬇️ SMP → TodayLesson 반영 스트림 구독
  void _tryWireNotesSync() {
    try {
      final svc = XscSyncService.instance;
      final stream = svc.notesStream;
      if (stream is Stream<String>) {
        _notesSub?.cancel();
        _notesSub = stream.listen((txt) {
          if (!mounted) return;
          if (_memoCtl.text == txt) return;
          _memoChangeFromStream = true;
          _hydratingMemo = true;
          _memoCtl.text = txt; // 주입
          _hydratingMemo = false;
          _memoChangeFromStream = false;
          _scheduleSave(); // DB 반영
        });

        // ⬇️ 추가: 현재 편집값 1회 브로드캐스트 (루프 방지 조건 하에)
        Future.microtask(() {
          try {
            svc.pushNotes(_memoCtl.text);
          } catch (_) {}
        });
      }
    } catch (_) {}
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

    _hydratingMemo = true; // ⬅️ 시작
    _subjectCtl.text = (row['subject'] ?? '').toString();
    _memoCtl.text = (row['memo'] ?? '').toString();
    _youtubeCtl.text = (row['youtube_url'] ?? '').toString();
    _hydratingMemo = false;

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

      _hydratingMemo = true;
      _subjectCtl.text = subject;
      _memoCtl.text = memo;
      _youtubeCtl.text = youtube;
      _hydratingMemo = false;

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

  Future<void> _maybeAutoPrefillFromLatestPast() async {
    if (_autoPrefillTried) return;
    _autoPrefillTried = true;
    try {
      if (_todayLinks.isNotEmpty) return;

      final now = DateTime.now();
      final startToday = DateTime(now.year, now.month, now.day);
      final to = startToday.subtract(const Duration(seconds: 1));

      final pastList = await _service.listByStudent(
        _studentId,
        to: to,
        limit: 1,
        asc: false,
      );
      if (pastList.isEmpty) return;

      final latest = Map<String, dynamic>.from(pastList.first);
      final historyId = (latest['id'] ?? '').toString();
      if (historyId.isEmpty) return;

      await _prefillFromHistory(historyId);

      final links = await _links.listByLesson(historyId);

      final List attachmentsRaw = (latest['attachments'] is List)
          ? latest['attachments'] as List
          : [];

      Map<String, dynamic> normalizeAttachment(dynamic a) {
        if (a is Map) return Map<String, dynamic>.from(a);
        final s = a?.toString() ?? '';
        return <String, dynamic>{
          'url': s,
          'path': s,
          'name': s.split('/').last,
        };
      }

      final atts = attachmentsRaw.map(normalizeAttachment).toList();

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
      // 일부 구현에서 List<Object>로 들어오는 경우가 있어 캐스팅 보강
      final casted = (hits as List).cast<KeywordItem>();
      if (!mounted) return;
      setState(() => _filteredItems = casted.isNotEmpty ? casted : _items);
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

      final memoNow = _memoCtl.text.trim();
      // 동일하면 업서트 스킵
      if (_lastSavedMemo != null && _lastSavedMemo == memoNow) {
        _lastSavedAt = DateTime.now();
        _setStatus(SaveStatus.saved);
        return;
      }

      await _service.upsert({
        'id': _lessonId,
        'student_id': _studentId,
        'date': _todayDateStr,
        if (((_teacherId ?? '')).isNotEmpty) 'teacher_id': _teacherId,
        'subject': _subjectCtl.text.trim(),
        'memo': memoNow, // ⬅ 단일 원본
        'keywords': _selectedKeywords.toList(),
        'attachments': attachmentsForSave,
        'youtube_url': _youtubeCtl.text.trim(),
      });

      _lastSavedAt = DateTime.now();
      _lastSavedMemo = memoNow;
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
        if (r) {
          ok++;
        } else {
          fail++;
        }
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

    // ===== 링크/첨부 열기: 미디어면 항상 SMP =====
  Future<void> _openLessonLink(Map<String, dynamic> link) async {
    // 🔒 더블클릭/중복탭 시 두 번째 이후 호출 무시
    if (_openingLessonLink) {
      return;
    }
    _openingLessonLink = true;

    try {
      final kind = (link['kind'] ?? '').toString();

      if (kind == 'resource') {
        try {
          final rf = ResourceFile.fromMap({
            'id': (link['id'] ?? '').toString(),
            'curriculum_node_id': link['curriculum_node_id'],
            'title': (link['resource_title'] ?? '').toString(),
            'filename': (link['resource_filename'] ?? 'resource').toString(),
            'mime_type': link['resource_mime_type'],
            'size_bytes': link['resource_size'],
            'storage_bucket':
                (link['resource_bucket'] ?? _defaultResourceBucket).toString(),
            'storage_path': (link['resource_path'] ?? '').toString(),
            'created_at': link['created_at'],
            'content_hash':
                (link['resource_content_hash'] ??
                        link['content_hash'] ??
                        link['hash'])
                    ?.toString(),
          });

          if (!XscSyncService.instance.isMediaEligibleForXsc(rf)) {
            // 미디어가 아니면: 기존처럼 서명 URL 열기
            await _links.openFromLessonLink(
              LessonLinkItem(
                id: (link['id'] ?? '').toString(),
                lessonId: (link['lesson_id'] ?? _lessonId ?? '').toString(),
                title: (link['resource_title'] ?? '').toString().isNotEmpty
                    ? link['resource_title'].toString()
                    : (link['resource_filename'] ?? 'resource').toString(),
                resourceBucket:
                    (link['resource_bucket'] ?? _defaultResourceBucket)
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
            return;
          }

          // 미디어면: SMP로 항상 진입 (내장 플레이어)
          final prep = await XscSyncService.instance.prepareForBuiltInPlayer(
            resource: rf,
            studentId: _studentId,
          );

          await SmartMediaPlayerScreen.push(
            context,
            SmartMediaPlayerScreen(
              studentId: prep.studentId,
              mediaHash: prep.mediaHash,
              mediaPath: prep.mediaPath,
              studentDir: prep.studentDir,
              initialSidecar: prep.sidecarPath,
            ),
          );
        } catch (e) {
          _showError('리소스 열기 실패: $e');
        }
        return;
      }

      // node 링크는 기존 동작 유지
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
    } finally {
      // 🔓 SMP 화면에서 돌아왔을 때 / 에러 났을 때 모두 해제
      _openingLessonLink = false;
    }
  }


  // ===== 배정 리소스 추가 (다이얼로그 포함) =====
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

    // 2) curriculum_nodes 트리에서 node_id -> 루트 타이틀 맵 생성
    final nodesRaw = await _curr.listNodes();
    if (!mounted) return null;

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

    return showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _AssignedResourcesPickerDialog(
        assigned: assigned
            .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
            .toList(),
        defaultBucket: _defaultResourceBucket,
        nodeRootTitleMap: nodeRootTitleMap,
        studentId: _studentId,
        curr: _curr,
      ),
    );
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('오늘 수업')),
      body: SingleChildScrollView(
        controller: _scrollCtl,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1) 빠른 실행 바: 링크/업로드/유튜브
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

                    // 업로드 확장 패널
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
                                  setState(() {});
                                  // 링크 섹션 갱신
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

            // 2) 오늘 레슨 링크
            Row(
              children: [
                Text('오늘 레슨 링크', style: _sectionH1(context)),
                const SizedBox(width: 8),
                if (!_selectMode && _todayLinks.isNotEmpty)
                  TextButton(
                    onPressed: _enterSelectMode,
                    child: const Text('선택 삭제'),
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
              ],
            ),
            const SizedBox(height: 6),
            _buildLessonLinksListPlain(),

            const SizedBox(height: 16),

            // 5) 메모
            Text('수업 메모', style: _sectionH1(context)),
            const SizedBox(height: 6),
            TextField(
              controller: _memoCtl,
              decoration: const InputDecoration(
                hintText: '수업 중 메모를 기록하세요',
                border: OutlineInputBorder(),
              ),
              maxLines: 10,
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

  TextStyle _sectionH1(BuildContext ctx) =>
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700);

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

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: _todayLinks.map((m) {
          final id = (m['id'] ?? '').toString();
          final kind = (m['kind'] ?? '').toString();
          final isNode = kind == 'node';

          final isHover = _hoveredLinkId == id;
          final base = Theme.of(context).colorScheme.surfaceContainerHighest;
          final hoverBg = base.withOpacity(0.22);

          final bucket = (m['resource_bucket'] ?? _defaultResourceBucket)
              .toString();
          final path = (m['resource_path'] ?? '').toString();
          final filename = (m['resource_filename'] ?? '').toString();

          String _joinPath(String a, String b) =>
              [a, b].map((s) => s.trim()).where((s) => s.isNotEmpty).join('/');

          final tip = isNode
              ? '노드: ${(m['curriculum_node_id'] ?? '').toString()}'
              : _joinPath(bucket, _joinPath(path, filename));


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
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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

  // ignore: unused_field
  final GlobalKey _keywordsKey = GlobalKey();

  // (숨김) 키워드 컨트롤/검색/칩 — 코드 유지
  // ignore: unused_element
  Widget _buildKeywordControls() {
    return const SizedBox.shrink();
  }

  // ignore: unused_element
  Widget _buildKeywordSearchBox() {
    return const SizedBox.shrink();
  }

  // ignore: unused_element
  Widget _buildKeywordChips() {
    return const SizedBox.shrink();
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

  @override
  void dispose() {
    _notesSub?.cancel(); // ⬅ 추가
    _debounce?.cancel();
    _kwSearchDebounce?.cancel();
    _subjectCtl.dispose();
    _memoCtl.dispose();
    _youtubeCtl.dispose();
    _keywordSearchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }
}

// ======================= 배정 리소스 다중 선택 다이얼로그 =======================

class _AssignedResourcesPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> assigned;
  final String defaultBucket;
  final Map<String, String>? nodeRootTitleMap;
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
  final Map<String, Map<String, dynamic>> _selected = {};
  bool _selectAll = false;

  late final List<String> _roots;
  String _selectedRoot = '전체';

  List<Map<String, dynamic>> _list = const [];
  Timer? _searchDebounce;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _roots = _collectRoots(widget.assigned);
    _list = widget.assigned;

    _queryCtl.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 250), _runSearch);
      if (mounted) setState(() {});
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
      final path = v('storage_path');
      final last = _lastSegment(path);

      final bag = <String>[
        filename,
        _basename(filename),
        original,
        _basename(original),
        path,
        last,
        _basename(last),
        v('title'),
      ].where((e) => e.trim().isNotEmpty).map(_normKo).toList();

      return bag.any((h) => h.contains(needle));
    }

    setState(() {
      _list = widget.assigned.where(hit).toList();
      _loading = false;
    });
  }

  String _extractRoot(Map<String, dynamic> r) {
    String pickNonEmpty(List<String?> cands) {
      for (final c in cands) {
        final v = (c ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    final nid = (r['curriculum_node_id'] ?? '').toString();
    if (nid.isNotEmpty &&
        (widget.nodeRootTitleMap?.containsKey(nid) ?? false)) {
      final t = widget.nodeRootTitleMap![nid] ?? '';
      if (t.trim().isNotEmpty) return t.trim();
    }

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
    final list = s.toList()..sort((a, b) => a.compareTo(b));
    return ['전체', ...list];
  }

  String _originalTitleOf(Map<String, dynamic> r) {
    return (r['original_title'] ??
            r['original_filename'] ??
            r['filename'] ??
            r['title'] ??
            '')
        .toString()
        .trim();
  }

  List<Map<String, dynamic>> _filtered() {
    final q = _queryCtl.text.trim();

    List<Map<String, dynamic>> base = _list.where((r) {
      final path = (r['storage_path'] ?? r['path'] ?? '').toString().trim();
      final filename = (r['filename'] ?? '').toString().trim();
      return path.isNotEmpty && filename.isNotEmpty;
    }).toList();

    if (_selectedRoot != '전체') {
      base = base.where((r) => _extractRoot(r) == _selectedRoot).toList();
    }

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
    final k = _keyOf(r);
    setState(() {
      if (_selected.containsKey(k)) {
        _selected.remove(k);
      } else {
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 860,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '배정된 리소스 선택',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _queryCtl,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: '파일명/제목/경로 검색…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _selectedRoot,
                    onChanged: (v) => setState(() => _selectedRoot = v ?? '전체'),
                    items: _roots
                        .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                        .toList(),
                  ),
                  const Spacer(),
                  Checkbox(
                    value: _selectAll,
                    onChanged: (v) => _toggleAll(filtered, v ?? false),
                  ),
                  const Text('모두 선택'),
                ],
              ),
              const SizedBox(height: 8),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 4),
              Expanded(
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = filtered[i];
                      final k = _keyOf(r);
                      final checked = _selected.containsKey(k);
                      final title = _originalTitleOf(r).isNotEmpty
                          ? _originalTitleOf(r)
                          : (r['title'] ?? r['filename'] ?? '리소스').toString();
                      final path = (r['storage_path'] ?? r['path'] ?? '')
                          .toString();
                      final filename = (r['filename'] ?? '').toString();
                      final root = _extractRoot(r);

                      return ListTile(
                        dense: true,
                        leading: Checkbox(
                          value: checked,
                          onChanged: (_) => _toggleOne(r),
                        ),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '[$root] $path / $filename',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => _toggleOne(r),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final list = _selected.values.toList(growable: false);
                      Navigator.pop(context, list);
                    },
                    child: Text('추가 (${_selected.length})'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
