// lib/services/backup_service.dart
// v1.21.0 | 백업 JSON 생성/파싱/복원 (학생 단위)
// - ExportScreen/ImportScreen에서 사용하는 공개 API 제공
// - Supabase 스키마(v1.20) 기준
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

class BackupService {
  final SupabaseClient _supabase;
  BackupService._internal([SupabaseClient? client])
    : _supabase = client ?? Supabase.instance.client;
  static final BackupService instance = BackupService._internal();
  factory BackupService() => instance;
  BackupService.withClient(SupabaseClient client) : _supabase = client;

  /// Export: 특정 학생의 백업 JSON 원자료(Map) 구성
  /// - 화면에서 pretty JSON으로 변환해서 표시/저장
  Future<Map<String, dynamic>> buildStudentBackupJson(String studentId) async {
    if (studentId.isEmpty) {
      throw ArgumentError('studentId가 비어있습니다.');
    }

    final student = await _supabase
        .from('students')
        .select()
        .eq('id', studentId)
        .maybeSingle();

    if (student == null) {
      throw StateError('학생을 찾을 수 없습니다.');
    }

    final lessons = await _supabase
        .from('lessons')
        .select()
        .eq('student_id', studentId)
        .order('date', ascending: true);

    final summaries = await _supabase
        .from('summaries')
        .select()
        .eq('student_id', studentId)
        .order('created_at', ascending: true);

    // 필요 시 추가: keywords, teachers 등
    final keywords = await _supabase.from('feedback_keywords').select();

    return {
      'version': 'v1.21',
      'student_id': studentId,
      'student': Map<String, dynamic>.from(student as Map),
      'lessons': (lessons as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      'summaries': (summaries as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      'keywords': (keywords as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    };
  }

  /// Import: 사용자가 붙여넣은 백업 JSON 문자열을 안전 파싱
  Map<String, dynamic> parseBackupJson(String raw) {
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) {
        throw const FormatException('루트가 객체(JSON Object)가 아닙니다.');
      }
      return Map<String, dynamic>.from(decoded as Map);
    } on FormatException catch (e) {
      throw FormatException('JSON 형식 오류: ${e.message}');
    } catch (e) {
      throw FormatException('JSON 파싱 실패: $e');
    }
  }

  /// Import: 파싱된 데이터로부터 DB에 업서트
  /// 반환: (복원된 lesson 수, 복원된 summary 수)
  Future<(int, int)> restoreFromJson(Map<String, dynamic> data) async {
    final studentId = data['student_id'] as String?;
    if (studentId == null || studentId.isEmpty) {
      throw StateError('student_id가 없습니다.');
    }

    // lessons
    final rawLessons = (data['lessons'] as List? ?? const []);
    int nLessons = 0;
    for (final item in rawLessons) {
      final row = Map<String, dynamic>.from(item as Map);
      // student_id 보정
      row['student_id'] = studentId;
      await _supabase.from('lessons').upsert(row);
      nLessons++;
    }

    // summaries
    final rawSummaries = (data['summaries'] as List? ?? const []);
    int nSummaries = 0;
    for (final item in rawSummaries) {
      final row = Map<String, dynamic>.from(item as Map);
      row['student_id'] = studentId;

      // selected_lesson_ids, keywords가 List<String>일 수도, jsonb일 수도 있으니 안전 변환
      if (row['selected_lesson_ids'] is List) {
        row['selected_lesson_ids'] = (row['selected_lesson_ids'] as List)
            .toList();
      }
      if (row['keywords'] is List) {
        row['keywords'] = (row['keywords'] as List).toList();
      }

      await _supabase.from('summaries').upsert(row);
      nSummaries++;
    }

    return (nLessons, nSummaries);
  }
}
