// lib/services/backup_service.dart
// v1.21.1 | 불필요 타입체크 제거 + 안전 캐스팅/정규화
// - 불필요한 `is List` / `is Map` 형태의 타입 체크 제거(항상 true 경고 해소)
// - parseBackupJson: 직접 Map<String,dynamic> 캐스팅 + TypeError 래핑
// - restoreFromJson: List 필드 정규화는 try/catch로 처리(비-List면 그대로 둠)

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

    final studentRaw = await _supabase
        .from('students')
        .select()
        .eq('id', studentId)
        .maybeSingle();

    final Map<String, dynamic>? student = (studentRaw == null)
        ? null
        : Map<String, dynamic>.from(studentRaw);

    if (student == null) {
      throw StateError('학생을 찾을 수 없습니다.');
    }

    final lessonsRaw = await _supabase
        .from('lessons')
        .select()
        .eq('student_id', studentId)
        .order('date', ascending: true);

    final summariesRaw = await _supabase
        .from('summaries')
        .select()
        .eq('student_id', studentId)
        .order('created_at', ascending: true);

    final keywordsRaw = await _supabase
        .from('feedback_keywords')
        .select(); // 필요시 포함

    final lessons = (lessonsRaw as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final summaries = (summariesRaw as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final keywords = (keywordsRaw as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return {
      'version': 'v1.21',
      'student_id': studentId,
      'student': student,
      'lessons': lessons,
      'summaries': summaries,
      'keywords': keywords,
    };
  }

  /// Import: 사용자가 붙여넣은 백업 JSON 문자열을 안전 파싱
  Map<String, dynamic> parseBackupJson(String raw) {
    try {
      final decoded = json.decode(raw);
      // 직접 캐스팅 + TypeError를 FormatException으로 변환
      return Map<String, dynamic>.from(decoded as Map);
    } on TypeError {
      throw const FormatException('루트가 객체(JSON Object)가 아닙니다.');
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
      row['student_id'] = studentId; // 보정
      await _supabase.from('lessons').upsert(row);
      nLessons++;
    }

    // summaries
    final rawSummaries = (data['summaries'] as List? ?? const []);
    int nSummaries = 0;
    for (final item in rawSummaries) {
      final row = Map<String, dynamic>.from(item as Map);
      row['student_id'] = studentId;

      // List 필드 정규화: 타입 체크 대신 시도-실패 무시
      final sids = row['selected_lesson_ids'];
      if (sids != null) {
        try {
          row['selected_lesson_ids'] = List<dynamic>.from(sids as List);
        } catch (_) {
          // List가 아니면 원값 유지
        }
      }
      final kws = row['keywords'];
      if (kws != null) {
        try {
          row['keywords'] = List<dynamic>.from(kws as List);
        } catch (_) {
          // List가 아니면 원값 유지
        }
      }

      await _supabase.from('summaries').upsert(row);
      nSummaries++;
    }

    return (nLessons, nSummaries);
  }
}
