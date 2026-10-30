import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Client for the /my-subjects endpoints. Every call hits the Dart Frog
/// server and PostgreSQL; nothing is cached, mocked or hard-coded here.
/// The server decides what the teacher may see from the login token.
class MySubjectsApi {
  static Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  static Map<String, dynamic> _decode(http.Response r) {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
        'The server sent an unexpected response (${r.statusCode}).',
      );
    }

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception((data['message'] ?? 'Request failed').toString());
    }
    return data;
  }

  static List<Map<String, dynamic>> _list(Map<String, dynamic> d, String key) {
    final raw = d[key];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// The logged-in teacher's assigned subjects (one entry per subject and
  /// academic context, each with its assigned sections).
  static Future<List<Map<String, dynamic>>> subjects(String token) async {
    final r = await http.get(
      Uri.parse('${ApiService.baseUrl}/my-subjects'),
      headers: _headers(token),
    );
    return _list(_decode(r), 'subjects');
  }

  /// Assessments given to any of [classIds] (all must be the teacher's own).
  static Future<List<Map<String, dynamic>>> assessments(
    String token,
    List<int> classIds,
  ) async {
    final r = await http.get(
      Uri.parse('${ApiService.baseUrl}/my-subjects/assessments').replace(
        queryParameters: {'class_ids': classIds.join(',')},
      ),
      headers: _headers(token),
    );
    return _list(_decode(r), 'assessments');
  }

  /// Creates a draft assessment for the chosen sections.
  static Future<Map<String, dynamic>> createAssessment(
    String token, {
    required List<int> classIds,
    required String title,
    required String assessmentType,
  }) async {
    final r = await http.post(
      Uri.parse('${ApiService.baseUrl}/my-subjects/assessments'),
      headers: _headers(token),
      body: jsonEncode({
        'class_ids': classIds,
        'title': title,
        'assessment_type': assessmentType,
      }),
    );
    return Map<String, dynamic>.from(_decode(r)['assessment'] as Map);
  }

  /// Students and assessments of ONE Subject + Section.
  static Future<Map<String, dynamic>> scorebook(
    String token,
    int classId,
  ) async {
    final r = await http.get(
      Uri.parse('${ApiService.baseUrl}/my-subjects/classes/$classId/scorebook'),
      headers: _headers(token),
    );
    return _decode(r);
  }

  /// Records (or removes) the teacher's confirmation that a student was
  /// absent for an assessment.
  static Future<void> setAbsent(
    String token, {
    required int classId,
    required int examId,
    required int studentId,
    required bool absent,
  }) async {
    final r = await http.put(
      Uri.parse('${ApiService.baseUrl}/my-subjects/classes/$classId/absences'),
      headers: _headers(token),
      body: jsonEncode({
        'exam_id': examId,
        'student_id': studentId,
        'absent': absent,
      }),
    );
    _decode(r);
  }
}
