// lib/screens/lesson/lesson_history_screen.dart
// v1.60.0-ui | 히스토리 링크: ‘열기’ 단일화(동기화 포함), XSC 동기화 버튼 제거
// - links 로딩: resource_bucket/resource_path/resource_filename/resource_title 선택
// - 리소스 조인 제거(불필요). 링크 메타로 바로 표시/실행
// - XSC 동기화/기본앱 열기: 링크 메타로 ResourceFile 구성
// - 이전 fix 유지: select 제네릭 제거, inFilter 사용 제거, FileService.openLocal/OpenUrl 사용

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/resource_service.dart';
import '../../routes/app_routes.dart';
import '../../services/lesson_service.dart';
import '../../services/auth_service.dart';
import '../../services/file_service.dart';
import '../../services/log_service.dart';
import '../../ui/components/file_clip.dart';
import '../../services/lesson_links_service.dart';
import '../../models/resource.dart';
// XSC 동기화/리소스 메타
import '../../services/xsc_sync_service.dart';

class LessonHistoryScreen extends StatefulWidget {
  const LessonHistoryScreen({super.key});

  @override
  State<LessonHistoryScreen> createState() => _LessonHistoryScreenState();
}

class _LessonHistoryScreenState extends State<LessonHistoryScreen> {
  final LessonService _service = LessonService();

  final int _pageLimit = 30;
  int _offset = 0;
  bool _hasMore = true;

  final _scroll = ScrollController();

  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  late String _studentId;
  DateTime? _from;
  DateTime? _to;

  String _query = '';
  Timer? _debounce;

  // 행 단위 삭제 진행상태
  final Set<String> _deleting = {};

  // lesson_links 캐시: lessonId -> links[]
  final Map<String, List<Map<String, dynamic>>> _linksCache = {};
  final Set<String> _linksLoading = {};

  final DateFormat _date = DateFormat('yyyy.MM.dd');
  final DateFormat _month = DateFormat('yyyy.MM');

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
        if (!_loading) _load();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final raw = ModalRoute.of(context)?.settings.arguments;
    final args = (raw is Map)
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    _studentId =
        (args['studentId'] as String?)?.toString().trim() ??
        AuthService().currentStudent?.id ??
        '';

    _from = args['from'] is DateTime ? args['from'] as DateTime? : _from;
    _to = args['to'] is DateTime ? args['to'] as DateTime? : _to;

    if (_studentId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('잘못된 진입입니다. 학생 정보가 누락되었습니다.')),
        );
        Navigator.maybePop(context);
      });
      return;
    }

    _resetAndLoad();
  }

  void _resetAndLoad() {
    setState(() {
      _rows = [];
      _offset = 0;
      _hasMore = true;
      _error = null;
      _loading = true;
      _deleting.clear();

      _linksCache.clear();
      _linksLoading.clear();
    });
    _load();
  }

  Future<void> _load() async {
    if (!_hasMore && _offset > 0) return;

    setState(() => _loading = true);
    try {
      final chunk = await _service.listByStudentPaged(
        _studentId,
        from: _from,
        to: _to,
        query: _query.isEmpty ? null : _query,
        limit: _pageLimit,
        offset: _offset,
        asc: false,
      );

      final existingIds = _rows.map((e) => e['id']?.toString()).toSet();
      final filtered = chunk
          .where((e) {
            final id = (e['id'] ?? '').toString();
            return id.isEmpty || !existingIds.contains(id);
          })
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e));

      if (!mounted) return;
      setState(() {
        _rows.addAll(filtered);
        _loading = false;
        _hasMore = chunk.length == _pageLimit;
        _offset += chunk.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '불러오는 중 오류가 발생했어요.\n${e.toString()}';
      });
    }
  }

  Future<void> _refresh() async {
    _resetAndLoad();
  }

  void _setQuickRange(Duration d) {
    final now = DateTime.now();
    setState(() {
      _to = DateTime(now.year, now.month, now.day, 23, 59, 59);
      _from = _to!.subtract(d);
    });
    _resetAndLoad();
  }

  Future<void> _pickRange() async {
    final initialFirst =
        _from ?? DateTime.now().subtract(const Duration(days: 30));
    final initialLast = _to ?? DateTime.now();

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: DateTimeRange(start: initialFirst, end: initialLast),
      helpText: '조회 기간 선택',
      locale: const Locale('ko'),
    );
    if (picked != null) {
      setState(() {
        _from = DateTime(
          picked.start.year,
          picked.start.month,
          picked.start.day,
          0,
          0,
          0,
        );
        _to = DateTime(
          picked.end.year,
          picked.end.month,
          picked.end.day,
          23,
          59,
          59,
        );
      });
      _resetAndLoad();
    }
  }

  Map<String, List<Map<String, dynamic>>> _groupByMonth(
    List<Map<String, dynamic>> rows,
  ) {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final m in rows) {
      final d = _parseDate(m['date']);
      final key = d != null ? _month.format(d) : '기타';
      grouped.putIfAbsent(key, () => []).add(m);
    }
    final sorted = Map.fromEntries(
      grouped.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
    for (final e in sorted.entries) {
      e.value.sort((a, b) {
        final da = _parseDate(a['date']) ?? DateTime(1970);
        final db = _parseDate(b['date']) ?? DateTime(1970);
        return db.compareTo(da);
      });
    }
    return sorted;
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    final s = v.toString();
    try {
      if (RegExp(r'^\d{4}[./-]\d{2}[./-]\d{2}').hasMatch(s)) {
        final normalized = s.replaceAll('.', '-').replaceAll('/', '-');
        return DateTime.tryParse(normalized);
      }
      return DateTime.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  // ===== CSV (RFC4180 + UTF-8 BOM) =====
  String _csvEscape(String v) {
    final escaped = v.replaceAll('"', '""');
    return '"$escaped"';
  }

  String _xscPathOf(Map<String, dynamic> link) {
    for (final k in const [
      'xsc_storage_path',
      'xsc_path',
      'xsc_key',
      'xsc_storage_key',
    ]) {
      final v = (link[k] ?? '').toString();
      if (v.isNotEmpty) return v;
    }
    return '';
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

  /// 오디오/비디오 판별(원본 열기 보조메뉴용)
  bool _isAudioName(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.mp3') ||
        n.endsWith('.m4a') ||
        n.endsWith('.wav') ||
        n.endsWith('.aif') ||
        n.endsWith('.aiff') ||
        n.endsWith('.mp4') || // 영상도 오디오 추출 케이스
        n.endsWith('.mov');
  }


  Future<void> _exportCsv() async {
    final headers = ['date', 'subject', 'memo', 'next_plan', 'keywords'];
    final buf = StringBuffer();
    buf.writeln(headers.map(_csvEscape).join(','));

    for (final m in _rows) {
      final d = (m['date'] ?? '').toString();
      final s = (m['subject'] ?? '').toString().replaceAll('\r\n', '\n');
      final memo = (m['memo'] ?? '').toString().replaceAll('\r\n', '\n');
      final next = (m['next_plan'] ?? '').toString().replaceAll('\r\n', '\n');
      final kw = (m['keywords'] is List)
          ? (m['keywords'] as List).join('|')
          : '';

      buf.writeln([d, s, memo, next, kw].map(_csvEscape).join(','));
    }

    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(buf.toString())];
    final filename =
        'lesson_history_${_studentId}_${DateTime.now().millisecondsSinceEpoch}.csv';

    final f = await FileService.saveBytesFile(filename: filename, bytes: bytes);

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('CSV 저장 완료: ${f.path}')));
  }

  Future<void> _navigateToTodayLesson(Map<String, dynamic> args) async {
    if (!mounted) return;
    try {
      unawaited(
        LogService.insertLog(
          type: 'history_to_today',
          payload: {'student_id': _studentId, 'args': args},
        ),
      );
      await Navigator.of(
        context,
      ).pushNamed(AppRoutes.todayLesson, arguments: args);
      unawaited(
        LogService.insertLog(
          type: 'history_to_today_ok',
          payload: {'student_id': _studentId},
        ),
      );
    } catch (e) {
      if (!mounted) return;
      unawaited(
        LogService.insertLog(
          type: 'history_to_today_fail',
          payload: {'student_id': _studentId, 'error': e.toString()},
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오늘 수업 화면 이동 실패: $e')));
    }
  }

  Future<void> _confirmAndDelete(Map<String, dynamic> m) async {
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('삭제할 수 없는 항목입니다(식별자 없음)')));
      return;
    }

    if (_deleting.contains(id)) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('삭제'),
        content: const Text('이 수업 기록을 삭제할까요?\n첨부가 있다면 스토리지도 정리됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    setState(() => _deleting.add(id));
    try {
      final attachments = (m['attachments'] is List)
          ? (m['attachments'] as List)
          : const [];
      for (final a in attachments) {
        final map = (a is Map)
            ? Map<String, dynamic>.from(a)
            : {'url': a.toString(), 'path': a.toString()};
        final urlOrPath = (map['url'] ?? map['path'] ?? '').toString();
        if (urlOrPath.isNotEmpty) {
          unawaited(FileService().delete(urlOrPath));
        }
      }

      final deleted = await _service.deleteById(id);
      if (!deleted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('삭제되지 않았어요. 권한/정책을 확인해주세요.')),
          );
        }
        return;
      }

      final still = await _service.exists(id);
      if (still) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('삭제 확인 실패: 항목이 여전히 존재합니다.')),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          _rows.removeWhere((e) => (e['id'] ?? '').toString() == id);
          _linksCache.remove(id);
          _linksLoading.remove(id);
        });
      }

      unawaited(
        LogService.insertLog(
          type: 'history_delete',
          payload: {'student_id': _studentId, 'lesson_id': id},
        ),
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('삭제 완료')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(id));
      }
    }
  }

  // ---------- lesson_links lazy load ----------
  // ---------- lesson_links lazy load ----------
  Future<void> _ensureLinksLoaded(String lessonId) async {
    if (_linksCache.containsKey(lessonId) || _linksLoading.contains(lessonId)) {
      return;
    }
    _linksLoading.add(lessonId);
    if (mounted) setState(() {});

    try {
      // v1.66: 서비스 경유(뷰→실테이블 폴백 내장)
      final svc = LessonLinksService();
      final links = await svc.listByLesson(lessonId);
      _linksCache[lessonId] = links;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('링크 불러오기 실패: $e')));
      _linksCache[lessonId] = const [];
    } finally {
      _linksLoading.remove(lessonId);
      if (mounted) setState(() {});
    }
  }


  // ---------- 기본앱 열기 ----------
  

  Widget _sectionHeader(String month) {
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      color: bg,
      child: Text(
        month,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Text(
      t,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _kvSection(String title, String value, {String? badge}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _sectionTitle(title),
              if (badge != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                  ),
                  child: Text(
                    badge,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: '복사',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('클립보드에 복사했습니다')));
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(value),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildLinksSection(String lessonId) {
    final isLoading = _linksLoading.contains(lessonId);
    final links = _linksCache[lessonId];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('연결된 파일'),
          const SizedBox(height: 8),
          if (isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('불러오는 중…'),
                ],
              ),
            )
          else if (links == null)
            OutlinedButton.icon(
              onPressed: () => _ensureLinksLoaded(lessonId),
              icon: const Icon(Icons.link),
              label: const Text('링크 불러오기'),
            )
          else if (links.isEmpty)
            const Text('연결된 파일이 없습니다')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: links.map((l) {
                final filename = (l['resource_filename'] ?? '').toString();
                final title = (l['resource_title'] ?? '').toString();
                final displayName =
                    (title.isNotEmpty ? title : filename).isEmpty
                    ? '리소스'
                    : (title.isNotEmpty ? title : filename);
                final xscPath = _xscPathOf(l);
                final xscBadge = xscPath.isNotEmpty ? 'XSC' : null;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if ((l['xsc_updated_at'] ?? '')
                                .toString()
                                .isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Tooltip(
                                message:
                                    '최근 저장: ${_fmtLocalStamp((l['xsc_updated_at'] ?? '').toString())}',
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.tertiaryContainer,
                                  ),
                                  child: Text(
                                    '최근 저장본',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                            ],
                            if (xscBadge != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.tertiaryContainer,
                                ),
                                child: Text(
                                  xscBadge,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        // 기존 Wrap의 버튼들 교체
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: () async {
                                try {
                                  await XscSyncService().openFromLessonLinkMap(
                                    link: l,
                                    studentId: _studentId,
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('열기 실패: $e')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('열기'),
                            ),
                                if (_isAudioName(
                              (l['resource_filename'] ?? '').toString(),
                            ))
                              OutlinedButton.icon(
                                onPressed: () async {
                                  try {
                                    // 원본(사본 저장 후 기본앱)으로 열기
                                    final bucket =
                                        (l['resource_bucket'] ?? 'resources')
                                            .toString();
                                    final path = (l['resource_path'] ?? '')
                                        .toString();
                                    final name =
                                        (l['resource_filename'] ?? 'resource')
                                            .toString();

                                    final rf = ResourceFile.fromMap({
                                      'id': (l['id'] ?? '').toString(),
                                      'curriculum_node_id':
                                          l['curriculum_node_id'],
                                      'title': (l['resource_title'] ?? '')
                                          .toString(),
                                      'filename': name,
                                      'mime_type': null,
                                      'size_bytes': null,
                                      'storage_bucket': bucket,
                                      'storage_path': path,
                                      'created_at': l['created_at'],
                                    });

                                    final url = await ResourceService()
                                        .signedUrl(rf);
                                    await FileService()
                                        .saveUrlToWorkspaceAndOpen(
                                          studentId: _studentId,
                                          filename: name,
                                          url: url,
                                        );
                                  } catch (e) {
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('원본 열기 실패: $e')),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.audiotrack),
                                label: const Text('원본 mp3로 열기'),
                              ),



                            // (선택) 고급: 읽기전용 즉시열기 - 임시파일로만 열고 워처/동기화 안 걸림
                            // OutlinedButton.icon(
                            //   onPressed: () => _openQuickViewReadOnly(l),
                            //   icon: const Icon(Icons.visibility),
                            //   label: const Text('읽기 전용으로 보기'),
                            // ),
                          ],
                        ),

                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> m) {
    final idStr = (m['id'] ?? '').toString();
    final isDeleting = _deleting.contains(idStr);

    final date = _parseDate(m['date']);
    final dateStr = date != null
        ? _date.format(date)
        : (m['date'] ?? '').toString();
    final subject = (m['subject'] ?? '').toString();
    final memo = (m['memo'] ?? '').toString();
    final nextPlan = (m['next_plan'] ?? '').toString();
    final List attachments = (m['attachments'] ?? []) as List;
    final List keywords = (m['keywords'] ?? []) is List
        ? (m['keywords'] as List)
        : const [];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        title: Text(
          '$dateStr  —  $subject',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: memo.isEmpty
            ? null
            : Text(memo, maxLines: 1, overflow: TextOverflow.ellipsis),
        onExpansionChanged: (open) {
          if (open) _ensureLinksLoaded(idStr);
        },
        children: [
          if (keywords.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: keywords
                    .map(
                      (e) => Chip(
                        label: Text(e.toString()),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(),
              ),
            ),
          if (memo.isNotEmpty) _kvSection('메모', memo),
          if (nextPlan.isNotEmpty) _kvSection('다음 계획', nextPlan, badge: 'NEXT'),

          if (attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('첨부'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: attachments.map<Widget>((a) {
                      if (a is Map) {
                        final m = Map<String, dynamic>.from(a);
                        return FileClip(
                          name: (m['name'] ?? m['path'] ?? m['url'] ?? '첨부')
                              .toString(),
                          path: (m['localPath'] ?? '').toString().isNotEmpty
                              ? (m['localPath'] as String)
                              : null,
                          url: (m['url'] ?? '').toString(),
                        );
                      } else {
                        final s = a.toString();
                        return FileClip(
                          name: s.split('/').isNotEmpty
                              ? s.split('/').last
                              : '첨부',
                          url: s,
                        );
                      }
                    }).toList(),
                  ),
                ],
              ),
            ),

          // 오늘수업 링크
          _buildLinksSection(idStr),

          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: isDeleting
                      ? null
                      : () async => _confirmAndDelete(m),
                  icon: isDeleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: Text(isDeleting ? '삭제 중…' : '삭제'),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: isDeleting
                      ? null
                      : () async {
                          final id = m['id'];
                          final args = {
                            'studentId': _studentId,
                            'fromHistoryId': id,
                          };
                          await _navigateToTodayLesson(args);
                        },
                  icon: const Icon(Icons.replay),
                  label: const Text('이 내용 복습하기'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapRefresh(Widget child) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        controller: (_loading && _rows.isEmpty) ? null : _scroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [child],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTeacher = AuthService().isTeacherLike;

    final periodLabel = () {
      if (_from == null && _to == null) return '전체 기간';
      final f = _from != null ? DateFormat('yyyy.MM.dd').format(_from!) : '—';
      final t = _to != null ? DateFormat('yyyy.MM.dd').format(_to!) : '—';
      return '$f ~ $t';
    }();

    Widget body;
    if (_loading && _rows.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
      return _wrapRefresh(body);
    } else if (_error != null) {
      body = _ErrorView(message: _error!, onRetry: _load);
      return _wrapRefresh(body);
    } else if (_rows.isEmpty) {
      body = _EmptyView(
        title: '기록이 없습니다',
        subtitle: '상단 기간/검색을 바꾸거나, 오늘 수업 화면에서 내용을 기록해 보세요.',
        onRefresh: _refresh,
      );
      return _wrapRefresh(body);
    } else {
      final grouped = _groupByMonth(_rows);
      final monthKeys = grouped.keys.toList();

      return Scaffold(
        appBar: AppBar(
          title: const Text('지난 수업 복습'),
          actions: [
            IconButton(
              tooltip: 'CSV 내보내기',
              onPressed: _exportCsv,
              icon: const Icon(Icons.download),
            ),
            if (isTeacher)
              IconButton(
                tooltip: '학생 변경',
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('학생 변경: 라우팅 연결 예정')),
                  );
                },
                icon: const Icon(Icons.switch_account),
              ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(108),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      _QuickChip(
                        label: '1개월',
                        onTap: () => _setQuickRange(const Duration(days: 30)),
                      ),
                      _QuickChip(
                        label: '3개월',
                        onTap: () => _setQuickRange(const Duration(days: 90)),
                      ),
                      _QuickChip(
                        label: '6개월',
                        onTap: () => _setQuickRange(const Duration(days: 180)),
                      ),
                      _QuickChip(
                        label: '전체',
                        onTap: () {
                          setState(() {
                            _from = null;
                            _to = null;
                          });
                          _resetAndLoad();
                        },
                      ),
                      ActionChip(
                        label: Text(periodLabel),
                        avatar: const Icon(Icons.event, size: 18),
                        onPressed: _pickRange,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '제목/메모/다음 계획 검색',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) {
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 350), () {
                        final next = v.trim();
                        if (_query != next) {
                          setState(() => _query = next);
                          _resetAndLoad();
                        }
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        body: ListView.separated(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: monthKeys.length + (_hasMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (_hasMore && i == monthKeys.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final month = monthKeys[i];
            final items = grouped[month]!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionHeader(month),
                const SizedBox(height: 4),
                ...items.map(_buildRow),
              ],
            );
          },
        ),
      );
    }
  }
}

class _QuickChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      avatar: const Icon(Icons.timelapse, size: 18),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Future<void> Function()? onRefresh;
  const _EmptyView({required this.title, this.subtitle, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hourglass_empty, size: 48),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, textAlign: TextAlign.center),
            ],
            if (onRefresh != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => onRefresh!.call(),
                icon: const Icon(Icons.refresh),
                label: const Text('새로고침'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
