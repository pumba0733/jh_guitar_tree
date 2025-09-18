// lib/services/student_service.dart
// v1.58.0 | attachMeToStudent RPC 추가: 학생-로그인 UID 자동 연결(학생 모드 첫 진입 시 호출)
// - 기존 기능 유지
// - findByNameAndLast4 / list / create / update / remove / fetchNamesByIds / fetchById 그대로

import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  // ---------- 내부 유틸 ----------
  String? _normNullable(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  String? _normPhoneLast4(String? v) {
    if (v == null) return null;
    final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    // 마지막 4자리만 저장(4자리 미만이면 그대로)
    return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
  }

  String? _dateOnly(DateTime? d) => (d?.toIso8601String())?.substring(0, 10);

  // ---------- 단건 조회 (RPC 우선) ----------
  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = _normPhoneLast4(last4) ?? '';
    if (n.isEmpty || l4.length != 4) return null;

    // Prefer RPC
    final rpcRes = await _client.rpc(
      'find_student',
      params: {'p_name': n, 'p_last4': l4},
    );

    if (rpcRes is Map && rpcRes.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(rpcRes));
    }
    if (rpcRes is List && rpcRes.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(rpcRes.first));
    }

    // Fallback
    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .eq('phone_last4', l4)
        .ilike('name', '%$n%')
        .limit(1);

    final list = (res as List);
    if (list.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(list.first));
    }
    return null;
  }

  // ---------- 목록 조회 ----------
  Future<List<Student>> list({
    String? query,
    int limit = 100,
    int offset = 0,
    String orderBy = 'created_at',
    bool ascending = false,
  }) async {
    var filter = _client.from(SupabaseTables.students).select();

    final q = (query ?? '').trim();
    if (q.isNotEmpty) {
      filter = filter.ilike('name', '%$q%');
    }

    final res = await filter
        .order(orderBy, ascending: ascending)
        .range(offset, offset + limit - 1);

    final list = (res as List);
    return list
        .map((e) => Student.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ---------- 생성 ----------
  Future<Student> create({
    required String name,
    String? phoneLast4,
    String? teacherId,

    // 설계 필드
    String? gender, // '남' | '여'
    bool isAdult = true,
    String? schoolName,
    int? grade,
    DateTime? startDate,
    String? instrument, // '통기타' | '일렉기타' | '클래식기타'
    String? memo,
    bool isActive = true,
  }) async {
    final payload = <String, dynamic>{
      'name': name.trim(),
      if (_normPhoneLast4(phoneLast4) != null)
        'phone_last4': _normPhoneLast4(phoneLast4),
      if (_normNullable(teacherId) != null)
        'teacher_id': _normNullable(teacherId),

      // 설계 필드
      'is_adult': isAdult,
      'is_active': isActive,
      if (_normNullable(gender) != null) 'gender': _normNullable(gender),
      if (_normNullable(schoolName) != null)
        'school_name': _normNullable(schoolName),
      if (grade != null) 'grade': grade,
      if (startDate != null) 'start_date': _dateOnly(startDate),
      if (_normNullable(instrument) != null)
        'instrument': _normNullable(instrument),
      if (_normNullable(memo) != null) 'memo': _normNullable(memo),
    };

    final res = await _client
        .from(SupabaseTables.students)
        .insert(payload)
        .select()
        .single();
    return Student.fromMap(Map<String, dynamic>.from(res));
  }

  // ---------- 수정 ----------
  Future<Student> update({
    required String id,
    String? name,
    String? phoneLast4,
    String? teacherId,

    // 설계 필드
    String? gender,
    bool? isAdult,
    String? schoolName,
    int? grade,
    DateTime? startDate,
    String? instrument,
    String? memo,
    bool? isActive,
  }) async {
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name.trim();
    if (phoneLast4 != null) patch['phone_last4'] = _normPhoneLast4(phoneLast4);
    if (teacherId != null) patch['teacher_id'] = _normNullable(teacherId);

    if (gender != null) patch['gender'] = _normNullable(gender);
    if (isAdult != null) patch['is_adult'] = isAdult;
    if (schoolName != null) patch['school_name'] = _normNullable(schoolName);
    if (grade != null) patch['grade'] = grade;
    if (startDate != null) patch['start_date'] = _dateOnly(startDate);
    if (instrument != null) patch['instrument'] = _normNullable(instrument);
    if (memo != null) patch['memo'] = _normNullable(memo);
    if (isActive != null) patch['is_active'] = isActive;

    final res = await _client
        .from(SupabaseTables.students)
        .update(patch)
        .eq('id', id)
        .select()
        .single();
    return Student.fromMap(Map<String, dynamic>.from(res));
  }

  // ---------- 삭제 ----------
  Future<void> remove(String id) async {
    await _client.from(SupabaseTables.students).delete().eq('id', id);
  }

  // ---------- 이름 맵 조회 ----------
  Future<Map<String, String>> fetchNamesByIds(Iterable<String> ids) async {
    final list = ids.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (list.isEmpty) return {};
    final res = await _client
        .from(SupabaseTables.students)
        .select('id, name')
        .inFilter('id', list);

    final rows = (res as List);
    final map = <String, String>{};
    for (final row in rows) {
      final m = Map<String, dynamic>.from(row);
      map[m['id'] as String] = m['name'] as String;
    }
    return map;
  }

  // ---------- 단건 조회 by ID ----------
  Future<Student?> fetchById(String id) async {
    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .eq('id', id)
        .maybeSingle();

    if (res == null) return null;
    return Student.fromMap(Map<String, dynamic>.from(res));
  }

  // ---------- NEW: 학생-토큰 연결(최초 진입 시 한 번 호출) ----------
  Future<void> attachMeToStudent(String studentId) async {
    final sid = studentId.trim();
    if (sid.isEmpty) return;
    try {
      await _client.rpc('attach_me_to_student', params: {'p_student_id': sid});
    } catch (_) {
      // 이미 연결되어 있거나 권한 이슈면 무시 (RLS는 이후 단계에서 판단)
    }
  }
}
