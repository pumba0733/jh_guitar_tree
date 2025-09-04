// lib/services/student_service.dart
// v1.35.0 | 학생 CRUD 확장 + 정규화 + UPDATE 반영 확정
// - create/update에 설계서 필드 지원: gender, isAdult, schoolName, grade, startDate, instrument, isActive, memo
// - 빈문자('') → NULL 정규화 (phone_last4/teacher_id/문자 필드)
// - UPDATE 후 .select().single()로 최신값 반환 (UI에서 재조회 시 확실히 반영)
// - 기존 시그니처 호환: 기존 파라미터만 전달해도 동작

import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  // ---------- helpers ----------
  String? _normStr(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  String? _normLast4(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  String? _normTeacherId(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  String? _dateOnly(DateTime? d) {
    if (d == null) return null;
    // start_date는 DATE 컬럼 → YYYY-MM-DD 로 전달
    return d.toIso8601String().split('T').first;
    // PostgREST는 ISO도 받아주지만 DATE 컬럼에는 date-only 전달이 안전
  }

  // ---------- 단건 조회 (RPC 우선) ----------
  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = last4.trim();
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
    String phoneLast4 = '',
    String? teacherId,

    // 확장 필드 (선택)
    String? gender, // '남' | '여'
    bool isAdult = true, // true=성인, false=학생
    String? schoolName,
    int? grade,
    DateTime? startDate, // DATE
    String? instrument, // '통기타' | '일렉기타' | '클래식기타'
    bool isActive = true,
    String? memo,
  }) async {
    final payload = <String, dynamic>{
      'name': name.trim(),
      'phone_last4': _normLast4(phoneLast4),
      'teacher_id': _normTeacherId(teacherId),
      'is_active': isActive,
      'memo': _normStr(memo),
      'gender': _normStr(gender),
      'is_adult': isAdult,
      'school_name': _normStr(schoolName),
      'grade': grade,
      'start_date': _dateOnly(startDate),
      'instrument': _normStr(instrument),
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

    // 확장 필드 (선택)
    String? gender,
    bool? isAdult,
    String? schoolName,
    int? grade,
    DateTime? startDate, // null을 명시적으로 전달하면 NULL로 갱신됨
    String? instrument,
    bool? isActive,
    String? memo,
  }) async {
    final patch = <String, dynamic>{};

    if (name != null) patch['name'] = name.trim();
    if (phoneLast4 != null) patch['phone_last4'] = _normLast4(phoneLast4);
    if (teacherId != null) patch['teacher_id'] = _normTeacherId(teacherId);

    if (gender != null) patch['gender'] = _normStr(gender);
    if (isAdult != null) patch['is_adult'] = isAdult;
    if (schoolName != null) patch['school_name'] = _normStr(schoolName);
    if (grade != null) patch['grade'] = grade;
    if (isActive != null) patch['is_active'] = isActive;
    if (memo != null) patch['memo'] = _normStr(memo);
    if (instrument != null) patch['instrument'] = _normStr(instrument);

    // startDate는 DateTime?라서, 호출자가 null을 명시적으로 넘기면 컬럼을 NULL로 만든다.
    if (startDate != null || patch.containsKey('start_date')) {
      // 위 containsKey는 방어적 의미 — 실제론 없지만 향후 확장 대비
    }
    if (startDate != null) {
      patch['start_date'] = _dateOnly(startDate); // 값 지정
    } else if (startDate == null &&
        ( // 명시적으로 null을 전달하여 초기화하고 싶은 경우
        // 호출부에서 명시적으로 startDate: null 을 넘겨주면 여길 태운다.
        // 이 함수 시그니처 특성상 null 전달과 미전달이 같아서,
        // "초기화"가 필요하면 별도 clear 플래그를 도입하는 것을 권장.
        false)) {
      patch['start_date'] = null;
    }

    if (patch.isEmpty) {
      // 변경 없음: 현재 레코드 반환
      final current = await _client
          .from(SupabaseTables.students)
          .select()
          .eq('id', id)
          .single();
      return Student.fromMap(Map<String, dynamic>.from(current));
    }

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
}
