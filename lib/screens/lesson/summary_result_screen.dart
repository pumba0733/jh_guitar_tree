// lib/screens/lesson/summary_result_screen.dart
// v1.29.2 | unused_import(dart:io) 제거
//
// 변경점(1.29.2):
// - 미사용 import: 'dart:io' 삭제 → unused_import 린트 해소
// - 나머지 로직/UX 동일 유지

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../../services/file_service.dart';

import '../../services/summary_service.dart';
import '../../models/summary.dart';
import '../../services/auth_service.dart';

class SummaryResultScreen extends StatefulWidget {
  const SummaryResultScreen({super.key});

  @override
  State<SummaryResultScreen> createState() => _SummaryResultScreenState();
}

class _SummaryResultScreenState extends State<SummaryResultScreen> {
  bool _inited = false;
  late final SummaryService _summaryService;

  String? _summaryId;
  String? _studentId;

  Future<Summary?>? _future;

  @override
  void initState() {
    super.initState();
    _summaryService = SummaryService();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return; // ⬅️ 가드
    _inited = true;

    final args = (ModalRoute.of(context)?.settings.arguments as Map?) ?? {};
    _summaryId = (args['summaryId'] as String?)?.trim();
    _studentId =
        (args['studentId'] as String?)?.trim() ??
        AuthService().currentStudent?.id;

    _future = _loadSummary();
    setState(() {}); // arguments 반영
  }

  Future<Summary?> _loadSummary() async {
    if (_summaryId != null && _summaryId!.isNotEmpty) {
      return _summaryService.getById(_summaryId!);
    }
    if (_studentId != null && _studentId!.isNotEmpty) {
      return _summaryService.getLatestByStudent(_studentId!);
    }
    return null;
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _loadSummary();
    });
    await _future;
  }

  // ---------- 유틸: 텍스트 조립/복사/저장 ----------

  String _buildMarkdown(Summary s) {
    final createdAtStr =
        s.createdAt?.toLocal().toIso8601String().split('T').first ?? '-';
    final periodStart = s.periodStart?.toString().split(' ').first ?? '-';
    final periodEnd = s.periodEnd?.toString().split(' ').first ?? '-';
    final type = s.type ?? '-';

    final buf = StringBuffer()
      ..writeln('# 수업 요약 결과')
      ..writeln()
      ..writeln('**요약 ID**: ${s.id}  ')
      ..writeln('**학생 ID**: ${s.studentId}  ')
      ..writeln('**유형**: $type  ')
      ..writeln('**작성일**: $createdAtStr  ')
      ..writeln('**기간**: $periodStart ~ $periodEnd  ')
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('## 🧑‍🎓 학생용 요약')
      ..writeln(
        s.resultStudent?.trim().isNotEmpty == true
            ? s.resultStudent!.trim()
            : '_(비어있음)_',
      )
      ..writeln()
      ..writeln('## 👪 보호자용 메시지')
      ..writeln(
        s.resultParent?.trim().isNotEmpty == true
            ? s.resultParent!.trim()
            : '_(비어있음)_',
      )
      ..writeln()
      ..writeln('## 📝 블로그용 텍스트')
      ..writeln(
        s.resultBlog?.trim().isNotEmpty == true
            ? s.resultBlog!.trim()
            : '_(비어있음)_',
      )
      ..writeln()
      ..writeln('## 👩‍🏫 강사용 리포트')
      ..writeln(
        s.resultTeacher?.trim().isNotEmpty == true
            ? s.resultTeacher!.trim()
            : '_(비어있음)_',
      );

    return buf.toString();
  }

  Future<void> _copyAll(Summary s) async {
    final text = _buildMarkdown(s);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('전체 내용이 클립보드에 복사되었습니다.')));
    }
  }

  Future<void> _copyText(String title, String? body) async {
    final content = body?.trim() ?? '';
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('“$title” 내용이 복사되었습니다.')));
  }

  Future<void> _exportMarkdown(Summary s) async {
    try {
      final md = _buildMarkdown(s);
      final filename = 'summary_${s.id}.md';

      // ⬇️ 임시폴더 대신 Downloads/문서 폴더에 저장
      final file = await FileService.saveTextFile(
        filename: filename,
        content: md,
      );

      // 데스크톱이면 바로 열기 시도(실패해도 무시)
      try {
        await OpenFilex.open(file.path);
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('내보냈습니다: ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('내보내기 실패: $e')));
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('수업 요약 결과')),
      body: FutureBuilder<Summary?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorView(
              message: '요약 로드 중 오류가 발생했습니다.\n${snapshot.error}',
              onRetry: _refresh,
            );
          }
          if (!snapshot.hasData || snapshot.data == null) {
            return _EmptyView(onRetry: _refresh);
          }

          final s = snapshot.data!;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _HeaderBar(
                    summary: s,
                    onCopyAll: () => _copyAll(s),
                    onExportMd: () => _exportMarkdown(s),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  sliver: SliverList.list(
                    children: [
                      _MetaCard(summary: s),
                      _Section(
                        title: '학생용 요약',
                        body: s.resultStudent,
                        onCopy: () => _copyText('학생용 요약', s.resultStudent),
                      ),
                      _Section(
                        title: '보호자용 메시지',
                        body: s.resultParent,
                        onCopy: () => _copyText('보호자용 메시지', s.resultParent),
                      ),
                      _Section(
                        title: '블로그용 텍스트',
                        body: s.resultBlog,
                        onCopy: () => _copyText('블로그용 텍스트', s.resultBlog),
                      ),
                      _Section(
                        title: '강사용 리포트',
                        body: s.resultTeacher,
                        onCopy: () => _copyText('강사용 리포트', s.resultTeacher),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// 상단 고정형 액션 바(전체 복사 / MD 내보내기)
class _HeaderBar extends StatelessWidget {
  final Summary summary;
  final VoidCallback onCopyAll;
  final VoidCallback onExportMd;

  const _HeaderBar({
    required this.summary,
    required this.onCopyAll,
    required this.onExportMd,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '요약 ID: ${summary.id}',
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: '전체 복사',
              child: IconButton(
                icon: const Icon(Icons.copy_all),
                onPressed: onCopyAll,
              ),
            ),
            Tooltip(
              message: 'Markdown 내보내기',
              child: IconButton(
                icon: const Icon(Icons.file_download),
                onPressed: onExportMd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 메타 정보 카드
class _MetaCard extends StatelessWidget {
  final Summary summary;
  const _MetaCard({required this.summary});

  String _fmtDate(DateTime? d) =>
      d == null ? '-' : d.toLocal().toIso8601String().split('T').first;

  @override
  Widget build(BuildContext context) {
    final created = summary.createdAt; // 모델에 createdAt만 존재
    return Card(
      margin: const EdgeInsets.only(bottom: 16, left: 0, right: 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('요약 메타', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  _MetaRow(label: '학생 ID', value: summary.studentId),
                  _MetaRow(label: '유형', value: summary.type ?? '-'),
                  _MetaRow(label: '작성일', value: _fmtDate(created)),
                  _MetaRow(
                    label: '기간',
                    value:
                        '${_fmtDate(summary.periodStart)} ~ ${_fmtDate(summary.periodEnd)}',
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

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final styleLabel = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
    final styleValue = Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: styleLabel),
        Text(value, style: styleValue),
      ],
    );
  }
}

// 섹션 카드(복사 버튼 + SelectableText)
class _Section extends StatelessWidget {
  final String title;
  final String? body;
  final VoidCallback? onCopy;

  const _Section({required this.title, required this.body, this.onCopy});

  @override
  Widget build(BuildContext context) {
    final isEmpty = body == null || body!.trim().isEmpty;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: isEmpty
            ? Text('$title: (비어있음)')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (onCopy != null)
                        Tooltip(
                          message: '복사',
                          child: IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: onCopy,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(body!),
                ],
              ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _EmptyView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('요약을 찾을 수 없습니다.'),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}
