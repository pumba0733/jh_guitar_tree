// lib/services/llm_service.dart
// v1.21.3 | Google Gemini API 연동 버전
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/app_env.dart';

class LlmService {
  Future<Map<String, String>> generateFourSummaries({
    required Map<String, dynamic> studentInfo,
    required List<Map<String, dynamic>> lessons,
    required Map<String, dynamic> condition, // {type:'기간별'|'키워드', ...}
  }) async {
    // 1) 하나의 prompt 문자열 만들기
    final prompt = StringBuffer()
      ..writeln("학생 정보: $studentInfo")
      ..writeln("레슨 목록: $lessons")
      ..writeln("조건: $condition")
      ..writeln("학생용 / 보호자용 / 블로그용 / 강사용 요약을 각각 작성해줘.")
      ..writeln(
        "출력은 JSON 형식으로: {\"student\":..., \"parent\":..., \"blog\":..., \"teacher\":...}",
      );

    // 2) Gemini 요청 payload
    final payload = {
      "contents": [
        {
          "role": "user",
          "parts": [
            {"text": prompt.toString()},
          ],
        },
      ],
    };

    final uri = Uri.parse("${AppEnv.llmEndpoint}?key=${AppEnv.llmApiKey}");
    final r = await http.post(
      uri,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('Gemini 요청 실패: ${r.statusCode} ${r.body}');
    }

    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final text =
        (data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '')
            as String;

    // 3) Gemini 응답 텍스트가 JSON 문자열일 걸 기대 → 파싱
    try {
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      return {
        'result_student': '${parsed['student'] ?? ''}',
        'result_parent': '${parsed['parent'] ?? ''}',
        'result_blog': '${parsed['blog'] ?? ''}',
        'result_teacher': '${parsed['teacher'] ?? ''}',
      };
    } catch (_) {
      // JSON 파싱 실패하면 그냥 전체 텍스트를 학생용에만 반환
      return {
        'result_student': text,
        'result_parent': '',
        'result_blog': '',
        'result_teacher': '',
      };
    }
  }
}
