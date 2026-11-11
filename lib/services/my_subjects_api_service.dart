import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Deep-link target used when routing from the Scanner's Post-Scoring Dialog
/// ("View in My Subjects") into `MySubjectsScreen`.
class MySubjectsScorebookTarget {
  const MySubjectsScorebookTarget({
    required this.classId,
    required this.examId,
    required this.studentId,
    this.studentNumber,
    this.studentName,
    this.sectionName,
    this.subjectId,
    this.attemptId,
  });

  final int classId;
  final int examId;
  final int studentId;
  final String? studentNumber;
  final String? studentName;
  final String? sectionName;
  final int? subjectId;
  final int? attemptId;
}

/// Global notifier observed by `MySubjectsScreen` to open a specific section's
/// scorebook and highlight/pulse the newly recorded student row.
final ValueNotifier<MySubjectsScorebookTarget?> mySubjectsScorebookTarget =
    ValueNotifier<MySubjectsScorebookTarget?>(null);

/// Client for the /my-subjects and scanner-to-scorebook endpoints. Every call
/// hits the Dart Frog server and PostgreSQL; nothing is mocked or hard-coded.
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
    String? gradingPeriod,
    String creationMode = 'builder',
    num? maximumScore,
  }) async {
    final r = await http.post(
      Uri.parse('${ApiService.baseUrl}/my-subjects/assessments'),
      headers: _headers(token),
      body: jsonEncode({
        'class_ids': classIds,
        'title': title,
        'assessment_type': assessmentType,
        'grading_period': ?gradingPeriod,
        'creation_mode': creationMode,
        'maximum_score': ?maximumScore,
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

  /// Records (or updates/upserts) a verified answer sheet scan into PostgreSQL
  /// (`exam_attempts` + `student_answers`) and clears any absence mark for that
  /// student on that exam.
  static Future<Map<String, dynamic>> recordScannedAttempt(
    String token, {
    required int examId,
    int? studentId,
    int? classId,
    String? studentNumber,
    String? sectionName,
    required List<Map<String, dynamic>> answers,
  }) async {
    final r = await http.post(
      Uri.parse('${ApiService.baseUrl}/attempts'),
      headers: _headers(token),
      body: jsonEncode({
        'exam_id': examId,
        'student_id': studentId,
        'class_id': classId,
        'student_number': studentNumber,
        'section': sectionName,
        'answers': answers,
      }),
    );
    return _decode(r);
  }

  /// Fetches full attempt details (including per-question verified answers)
  /// for a completed scorebook cell.
  static Future<Map<String, dynamic>> getAttemptDetail(
    String token,
    int attemptId,
  ) async {
    final r = await http.get(
      Uri.parse('${ApiService.baseUrl}/attempts/$attemptId'),
      headers: _headers(token),
    );
    final decoded = _decode(r);
    final attempt = decoded['attempt'];
    return attempt is Map<String, dynamic>
        ? attempt
        : (attempt is Map ? Map<String, dynamic>.from(attempt) : decoded);
  }

  /// Deletes a recorded student score for an exam in a section so the cell
  /// returns to `Pending`.
  static Future<void> deleteScore(
    String token, {
    required int classId,
    required int examId,
    required int studentId,
    int? attemptId,
  }) async {
    final r = await http.delete(
      Uri.parse('${ApiService.baseUrl}/my-subjects/classes/$classId/scorebook')
          .replace(
        queryParameters: {
          'exam_id': '$examId',
          'student_id': '$studentId',
          if (attemptId != null) 'attempt_id': '$attemptId',
        },
      ),
      headers: _headers(token),
      body: jsonEncode({
        'exam_id': examId,
        'student_id': studentId,
        'attempt_id': ?attemptId,
      }),
    );
    _decode(r);
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
  static Future<void> saveManualScore(String token,{required int classId,required int examId,required int studentId,required num? score}) async {
    final r=await http.put(Uri.parse('${ApiService.baseUrl}/my-subjects/classes/$classId/scorebook'),headers:_headers(token),body:jsonEncode({'exam_id':examId,'student_id':studentId,'score':score}));
    _decode(r);
  }
  static Future<void> saveGradingPreferences(String token,int classId,Map<String,num> preferences) async {
    final r=await http.put(Uri.parse('${ApiService.baseUrl}/my-subjects/classes/$classId/grading-preferences'),headers:_headers(token),body:jsonEncode(preferences));
    _decode(r);
  }

}
