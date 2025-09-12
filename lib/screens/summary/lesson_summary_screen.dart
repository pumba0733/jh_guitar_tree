// lib/screens/summary/lesson_summary_screen.dart
// v1.31.1 | 역할 가드 switch 정리 + 불필요 캐스트 제거
//
// 변경 요약 (v1.31.1):
// - 🧩 unreachable_switch_case 제거: 역할 가드 분기에서 teacher/admin이 불가능한 경로에 있었던 switch → if 분기 단순화
// - 🧹 unnecessary_cast 제거: args 파싱 시 raw as Map 캐스트 제거
// - 나머지: 기존 UX/로직(무한스크롤/검색/선택툴바/요약생성/Refresh) 동일 유지

import 'dart:async' show Timer, unawaited;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/auth_service.dart';
import '../../services/student_service.dart';
import '../../services/lesson_service.dart';
import '../../services/summary_service.dart';
import '../../services/log_service.dart';

import '../../models/summary.dart';
import '../../routes/app_routes.dart';

class LessonSummaryScreen extends StatefulWidget {
  const LessonSummaryScreen({super.key});

  @override
  State<LessonSummaryScreen> createState() => _LessonSummaryScreenState();
}

class _LessonSummaryScreenState extends State<LessonSummaryScreen> {
  final _formKey = GlobalKey<FormState>();

  // ===== 조건 =====
  String _type = '기간별'; // '기간별' | '키워드'
  DateTime? _from;
  DateTime? _to;
  final _keywordController = TextEditingController();
  final List<String> _keywords = [];

  // ===== 컨텍스트(필수) =====
  String? _studentId;
  String? _teacherId;

  // 학생 검색용(미지정 진입 시)
  final _stuNameCtl = TextEditingController();
  final _stuLast4Ctl = TextEditingController();
  bool _findingStudent = false;

  // ===== 레슨 목록(실데이터) =====
  final LessonService _lessonSvc = LessonService();
  final _scroll = ScrollController();
  final _rows = <Map<String, dynamic>>[];
  final _selectedLessonIds = <String>{};

  final int _pageLimit = 30;
  int _offset = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  String _query = '';
  Timer? _debounce;

  bool _roleChecked = false;
  bool _isTeacherOrAdmin = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _guardRoleAndMaybeLoad();
  }

  Future<void> _guardRoleAndMaybeLoad() async {
    // 역할 가드 (학생 접근 차단)
    try {
      final role = await AuthService().getRole();
      final ok = (role == UserRole.teacher || role == UserRole.admin);
      if (!mounted) return;
      setState(() {
        _isTeacherOrAdmin = ok;
        _roleChecked = true;
      });

      if (!ok) {
        // 학생 등은 역할별 홈으로 복귀
        final route = (role == UserRole.student)
            ? AppRoutes.studentHome
            : AppRoutes.login;
        Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
        return;
      }

      // 통과 시 args 파싱 및 초기 로드
      _parseArgsAndLoad();
    } catch (_) {
      if (!mounted) return;
      // 판정 실패 시 기본 통과(교사/관리자 가정) → args 파싱
      setState(() {
        _isTeacherOrAdmin = true;
        _roleChecked = true;
      });
      _parseArgsAndLoad();
    }
  }

  void _parseArgsAndLoad() {
    final raw = ModalRoute.of(context)?.settings.arguments;
    final args = (raw is Map)
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};

    _studentId = (args['studentId'] as String?)?.trim();
    _teacherId = (args['teacherId'] as String?)?.trim();
    // teacherId 미전달 시 auth user로 보강
    _teacherId ??= AuthService().currentAuthUser?.id;

    if (_studentId != null && _studentId!.isNotEmpty) {
      unawaited(_resetAndLoad());
    } else {
      setState(() {
        // 학생 미지정 진입 → 검색 카드 표시
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _debounce?.cancel();
    _keywordController.dispose();
    _stuNameCtl.dispose();
    _stuLast4Ctl.dispose();
    super.dispose();
  }

  // ======= 학생 선택 =======
  Future<void> _findAndSetStudent() async {
    final name = _stuNameCtl.text.trim();
    final last4 = _stuLast4Ctl.text.trim();
    if (name.isEmpty || last4.length != 4) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이름과 전화 뒤 4자리를 정확히 입력하세요.')));
      return;
    }
    setState(() => _findingStudent = true);
    try {
      final s = await StudentService().findByNameAndLast4(
        name: name,
        last4: last4,
      );
      if (!mounted) return;
      if (s == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('학생을 찾을 수 없습니다.')));
        return;
      }
      _studentId = s.id;
      _selectedLessonIds.clear();
      await _resetAndLoad();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('검색 실패: $e')));
    } finally {
      if (mounted) setState(() => _findingStudent = false);
    }
  }

  // ======= 레슨 로딩 =======
  void _maybeLoadMore() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      if (!_loading) {
        unawaited(_load());
      }
    }
  }

  Future<void> _resetAndLoad() async {
    if (!mounted) return;
    setState(() {
      _rows.clear();
      _offset = 0;
      _hasMore = true;
      _error = null;
    });
    await _load();
  }

  DateTime? _normalizeStart(DateTime? d) =>
      d == null ? null : DateTime(d.year, d.month, d.day, 0, 0, 0);
  DateTime? _normalizeEnd(DateTime? d) =>
      d == null ? null : DateTime(d.year, d.month, d.day, 23, 59, 59);

  Future<void> _load() async {
    if (_studentId == null || _studentId!.isEmpty) return;
    if (!_hasMore && _offset > 0) return;

    if (mounted) setState(() => _loading = true);
    try {
      final from = (_type == '기간별') ? _normalizeStart(_from) : null;
      final to = (_type == '기간별') ? _normalizeEnd(_to) : null;

      final chunk = await _lessonSvc.listByStudentPaged(
        _studentId!,
        from: from,
        to: to,
        query: _query.isEmpty ? null : _query,
        limit: _pageLimit,
        offset: _offset,
        asc: false,
      );

      // id 기준 dedupe
      final existingIds = _rows.map((e) => (e['id'] ?? '').toString()).toSet();
      final filtered = chunk
          .where((e) {
            final id = (e['id'] ?? '').toString();
            return id.isEmpty || !existingIds.contains(id);
          })
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e));

      if (!mounted) return;
      setState(() {
        _rows.addAll(filtered);
        _hasMore = chunk.length == _pageLimit;
        _offset += chunk.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '레슨을 불러오지 못했습니다.\n$e';
      });
    }
  }

  // ======= UI 동작 =======
  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialFirst = _from ?? DateTime(now.year, now.month, 1);
    final initialLast = _to ?? DateTime(now.year, now.month + 1, 0);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3),
      initialDateRange: DateTimeRange(start: initialFirst, end: initialLast),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
      await _resetAndLoad();
    }
  }

  void _addKeyword() {
    final v = _keywordController.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _keywords.add(v);
      _keywordController.clear();
    });
  }

  Future<void> _createSummary() async {
    if (_studentId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('학생을 먼저 선택하세요.')));
      return;
    }
    if (_type == '기간별' && (_from == null || _to == null)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('기간별 요약은 기간을 선택해야 합니다.')));
      return;
    }
    if (_selectedLessonIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('레슨을 1개 이상 선택하세요.')));
      return;
    }

    try {
      // 로깅은 비차단
      unawaited(
        LogService.insertLog(
          type: 'summary_create_request',
          payload: {
            'student_id': _studentId,
            'teacher_id': _teacherId,
            'type': _type,
            'count': _selectedLessonIds.length,
          },
        ),
      );

      final Summary summary = await SummaryService.instance
          .createSummaryForSelectedLessons(
            studentId: _studentId!,
            teacherId: _teacherId,
            type: _type,
            periodStart: _type == '기간별' ? _from : null,
            periodEnd: _type == '기간별' ? _to : null,
            keywords: _type == '키워드' ? _keywords : null,
            selectedLessonIds: _selectedLessonIds.toList(),
          );

      if (!mounted) return;

      unawaited(
        LogService.insertLog(
          type: 'summary_create_ok',
          payload: {'student_id': _studentId, 'summary_id': summary.id},
        ),
      );

      Navigator.of(context).pushNamed(
        AppRoutes.summaryResult,
        arguments: {'summaryId': summary.id, 'studentId': _studentId},
      );
    } catch (e) {
      if (!mounted) return;
      unawaited(
        LogService.insertLog(
          type: 'summary_create_fail',
          payload: {'student_id': _studentId, 'error': e.toString()},
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('요약 생성 실패: $e')));
    }
  }

  // ====== 빌드 ======
  @override
  Widget build(BuildContext context) {
    if (!_roleChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isTeacherOrAdmin) {
      // _guardRoleAndMaybeLoad에서 이미 라우팅했지만, 이중 안전망
      return const SizedBox.shrink();
    }

    final df = DateFormat('yyyy.MM.dd');

    final content = Form(
      key: _formKey,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          // ===== 학생 선택 섹션 =====
          if (_studentId == null) _buildStudentPicker(),

          // ===== 조건 섹션 =====
          Row(
            children: [
              const Text('유형: '),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _type,
                items: const [
                  DropdownMenuItem(value: '기간별', child: Text('기간별')),
                  DropdownMenuItem(value: '키워드', child: Text('키워드')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _type = v);
                  // 유형 변경 시 기간/검색 필터 즉시 반영
                  unawaited(_resetAndLoad());
                },
              ),
              const Spacer(),
              if (_type == '기간별')
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.event),
                  label: Text(
                    (_from != null && _to != null)
                        ? '${df.format(_from!)} ~ ${df.format(_to!)}'
                        : '기간 선택',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (_type == '키워드') ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keywordController,
                    decoration: const InputDecoration(
                      labelText: '키워드 추가',
                      hintText: '예: 박자, 피킹, 코드 체인지',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addKeyword(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _addKeyword, child: const Text('추가')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _keywords
                  .map(
                    (k) => Chip(
                      label: Text(k),
                      onDeleted: () => setState(() => _keywords.remove(k)),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
          ],

          const Divider(height: 32),

          // ===== 검색 =====
          if (_studentId != null) ...[
            TextField(
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
                    unawaited(_resetAndLoad());
                  }
                });
              },
            ),
            const SizedBox(height: 12),
          ],

          // ===== 레슨 리스트 =====
          if (_studentId == null) ...[
            const SizedBox(height: 8),
            const Text('학생을 선택하면 레슨 목록이 표시됩니다.'),
          ] else if (_loading && _rows.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ] else if (_error != null) ...[
            _ErrorView(
              message: _error!,
              onRetry: () {
                unawaited(_resetAndLoad());
              },
            ),
          ] else if (_rows.isEmpty) ...[
            _EmptyView(
              title: '레슨이 없습니다',
              subtitle: '기간/검색을 조정하거나 오늘 수업 화면에서 기록을 추가해 보세요.',
              onRefresh: _resetAndLoad,
            ),
          ] else ...[
            // 선택 툴바 (총 건수/전체선택/최근 N개)
            Row(
              children: [
                Text('총 ${_rows.length}건'),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _toggleAll,
                  child: Text(
                    (_rows.isNotEmpty &&
                            _selectedLessonIds.length == _rows.length)
                        ? '전체 해제'
                        : '전체 선택',
                  ),
                ),
                const Spacer(),
                Wrap(
                  spacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('최근 5'),
                      onPressed: () => _selectLatest(5),
                    ),
                    ActionChip(
                      label: const Text('최근 10'),
                      onPressed: () => _selectLatest(10),
                    ),
                    ActionChip(
                      label: const Text('최근 20'),
                      onPressed: () => _selectLatest(20),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),

            ..._rows.map(_buildRow),
            if (_hasMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Text('선택: ${_selectedLessonIds.length}개'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _createSummary,
                icon: const Icon(Icons.summarize),
                label: const Text('요약 생성'),
              ),
            ),
          ],
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('수업 요약'),
        actions: [
          if (_studentId != null) ...[
            IconButton(
              tooltip: '학생 변경',
              onPressed: () {
                setState(() {
                  _studentId = null;
                  _rows.clear();
                  _selectedLessonIds.clear();
                  _offset = 0;
                  _hasMore = true;
                  _error = null;
                });
              },
              icon: const Icon(Icons.switch_account),
            ),
            IconButton(
              tooltip: '선택 해제',
              onPressed: () {
                setState(() => _selectedLessonIds.clear());
              },
              icon: const Icon(Icons.clear_all),
            ),
            IconButton(
              tooltip: '새로고침',
              onPressed: () {
                unawaited(_resetAndLoad());
              },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (_studentId == null) return;
          await _resetAndLoad();
        },
        child: content,
      ),
    );
  }

  // ====== 위젯들 ======
  Widget _buildStudentPicker() {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('학생 선택', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _stuNameCtl,
                    decoration: const InputDecoration(
                      labelText: '이름',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _stuLast4Ctl,
                    decoration: const InputDecoration(
                      labelText: '전화 뒤 4자리',
                      border: OutlineInputBorder(),
                      isDense: true,
                      counterText: '',
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _findingStudent ? null : _findAndSetStudent,
                icon: _findingStudent
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: const Text('학생 찾기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> m) {
    final dateStr = (() {
      final v = m['date'];
      if (v == null) return '';
      final d = DateTime.tryParse(v.toString()) ?? DateTime.now();
      return DateFormat('yyyy.MM.dd').format(d);
    })();
    final id = (m['id'] ?? '').toString();
    final subject = (m['subject'] ?? '').toString().trim();
    final memo = (m['memo'] ?? '').toString().trim();

    final selected = _selectedLessonIds.contains(id);
    return CheckboxListTile(
      value: selected,
      onChanged: (v) {
        setState(() {
          if (v == true) {
            if (id.isNotEmpty) _selectedLessonIds.add(id);
          } else {
            _selectedLessonIds.remove(id);
          }
        });
      },
      title: Text('$dateStr  |  ${subject.isEmpty ? "(제목 없음)" : subject}'),
      subtitle: memo.isEmpty
          ? null
          : Text(memo, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  void _selectLatest(int n) {
    final ids = _rows
        .take(n)
        .map((m) => (m['id'] ?? '').toString())
        .where((s) => s.isNotEmpty);
    setState(() {
      _selectedLessonIds
        ..clear()
        ..addAll(ids);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_rows.isNotEmpty && _selectedLessonIds.length == _rows.length) {
        _selectedLessonIds.clear();
      } else {
        _selectedLessonIds
          ..clear()
          ..addAll(
            _rows
                .map((m) => (m['id'] ?? '').toString())
                .where((s) => s.isNotEmpty),
          );
      }
    });
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
