import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Error from the Academic Management API. [message] is safe to show;
/// [issues] carries the detail lines of a failed publish check.
class AcademicApiException implements Exception {
  AcademicApiException(this.message, {this.issues = const [], this.status});

  final String message;
  final List<String> issues;
  final int? status;

  @override
  String toString() => message;
}

/// Client for the /academic endpoints. Every call hits the Dart Frog server
/// and PostgreSQL; nothing is cached or mocked here.
class AcademicApi {
  static Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  static Future<Map<String, dynamic>> _send(
    String method,
    String path,
    String token, {
    Map<String, dynamic>? body,
    Map<String, String?>? query,
  }) async {
    final params = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.isNotEmpty) params[k] = v;
    });

    final uri = Uri.parse('${ApiService.baseUrl}/academic$path')
        .replace(queryParameters: params.isEmpty ? null : params);

    final http.Response response;
    switch (method) {
      case 'GET':
        response = await http.get(uri, headers: _headers(token));
      case 'POST':
        response = await http.post(
          uri,
          headers: _headers(token),
          body: jsonEncode(body ?? <String, dynamic>{}),
        );
      case 'PUT':
        response = await http.put(
          uri,
          headers: _headers(token),
          body: jsonEncode(body ?? <String, dynamic>{}),
        );
      case 'DELETE':
        response = await http.delete(uri, headers: _headers(token));
      default:
        throw ArgumentError('Unsupported method $method');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AcademicApiException(
        'The server sent an unexpected response (${response.statusCode}).',
        status: response.statusCode,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final issues = data['issues'];
      throw AcademicApiException(
        (data['message'] ?? 'Request failed').toString(),
        issues: issues is List ? issues.map((e) => e.toString()).toList() : [],
        status: response.statusCode,
      );
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

  static Map<String, dynamic> _one(Map<String, dynamic> d, String key) =>
      Map<String, dynamic>.from(d[key] as Map);

  // ---------- programs ----------

  static Future<List<Map<String, dynamic>>> programs(String token) async =>
      _list(await _send('GET', '/programs', token), 'programs');

  static Future<Map<String, dynamic>> createProgram(
    String token, {
    required String code,
    required String name,
    required String level,
    String? department,
  }) async =>
      _one(
        await _send('POST', '/programs', token, body: {
          'code': code,
          'name': name,
          'level': level,
          'department': department,
        }),
        'program',
      );

  static Future<Map<String, dynamic>> updateProgram(
    String token,
    int id, {
    required String code,
    required String name,
    required String level,
    String? department,
  }) async =>
      _one(
        await _send('PUT', '/programs/$id', token, body: {
          'code': code,
          'name': name,
          'level': level,
          'department': department,
        }),
        'program',
      );

  static Future<void> deleteProgram(String token, int id) async {
    await _send('DELETE', '/programs/$id', token);
  }

  // ---------- subject catalog ----------

  static Future<List<Map<String, dynamic>>> searchCatalog(
    String token,
    String q,
  ) async =>
      _list(
        await _send('GET', '/subjects', token, query: {'q': q}),
        'subjects',
      );

  // ---------- curricula ----------

  static Future<List<Map<String, dynamic>>> curricula(
    String token,
    int programId,
  ) async =>
      _list(
        await _send('GET', '/curricula', token,
            query: {'program_id': '$programId'}),
        'curricula',
      );

  static Future<Map<String, dynamic>> createCurriculum(
    String token, {
    required int programId,
    required String code,
    int? copyFromId,
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? electives,
  }) async =>
      _one(
        await _send('POST', '/curricula', token, body: {
          'program_id': programId,
          'code': code,
          if (copyFromId != null) 'copy_from_id': copyFromId,
          if (rows != null && rows.isNotEmpty) 'rows': rows,
          if (electives != null && electives.isNotEmpty) 'electives': electives,
        }),
        'curriculum',
      );

  static Future<Map<String, dynamic>> updateCurriculum(
    String token,
    int id, {
    required String code,
  }) async =>
      _one(
        await _send('PUT', '/curricula/$id', token, body: {'code': code}),
        'curriculum',
      );

  static Future<void> deleteCurriculum(String token, int id) async {
    await _send('DELETE', '/curricula/$id', token);
  }

  static Future<Map<String, dynamic>> publishCurriculum(
    String token,
    int id,
  ) async =>
      _one(await _send('POST', '/curricula/$id/publish', token), 'curriculum');

  static Future<List<String>> validateCurriculum(String token, int id) async {
    final d = await _send('GET', '/curricula/$id/validation', token);
    final issues = d['issues'];
    return issues is List ? issues.map((e) => e.toString()).toList() : [];
  }

  // ---------- curriculum subjects ----------

  static Future<List<Map<String, dynamic>>> subjects(
    String token,
    int curriculumId, {
    required int yearLevel,
    required int term,
    String? schoolYear,
  }) async =>
      _list(
        await _send('GET', '/curricula/$curriculumId/subjects', token, query: {
          'year_level': '$yearLevel',
          'term': '$term',
          'school_year': schoolYear,
        }),
        'subjects',
      );

  static Future<Map<String, dynamic>> addSubject(
    String token,
    int curriculumId,
    Map<String, dynamic> body,
  ) async =>
      _one(
        await _send('POST', '/curricula/$curriculumId/subjects', token,
            body: body),
        'subject',
      );

  static Future<Map<String, dynamic>> updateSubject(
    String token,
    int curriculumId,
    int id,
    Map<String, dynamic> body,
  ) async =>
      _one(
        await _send('PUT', '/curricula/$curriculumId/subjects/$id', token,
            body: body),
        'subject',
      );

  static Future<void> deleteSubject(
    String token,
    int curriculumId,
    int id,
  ) async {
    await _send('DELETE', '/curricula/$curriculumId/subjects/$id', token);
  }

  static Future<int> deleteTermSubjects(
    String token,
    int curriculumId, {
    required int yearLevel,
    required int term,
  }) async {
    final d = await _send(
      'DELETE',
      '/curricula/$curriculumId/subjects',
      token,
      query: {'year_level': '$yearLevel', 'term': '$term'},
    );
    return int.tryParse(d['deleted']?.toString() ?? '') ?? 0;
  }

  // ---------- list of electives ----------

  static Future<List<Map<String, dynamic>>> electives(
    String token,
    int curriculumId,
  ) async =>
      _list(
        await _send('GET', '/curricula/$curriculumId/electives', token),
        'electives',
      );

  static Future<Map<String, dynamic>> addElective(
    String token,
    int curriculumId,
    Map<String, dynamic> body,
  ) async =>
      _one(
        await _send('POST', '/curricula/$curriculumId/electives', token,
            body: body),
        'elective',
      );

  static Future<Map<String, dynamic>> updateElective(
    String token,
    int curriculumId,
    int id,
    Map<String, dynamic> body,
  ) async =>
      _one(
        await _send('PUT', '/curricula/$curriculumId/electives/$id', token,
            body: body),
        'elective',
      );

  static Future<void> deleteElective(
    String token,
    int curriculumId,
    int id,
  ) async {
    await _send('DELETE', '/curricula/$curriculumId/electives/$id', token);
  }

  // ---------- elective choice per school year ----------

  static Future<void> setSelection(
    String token,
    int curriculumId, {
    required int curriculumSubjectId,
    required int electiveId,
    required String schoolYear,
  }) async {
    await _send('PUT', '/curricula/$curriculumId/selections', token, body: {
      'curriculum_subject_id': curriculumSubjectId,
      'elective_id': electiveId,
      'school_year': schoolYear,
    });
  }

  static Future<void> clearSelection(
    String token,
    int curriculumId, {
    required int curriculumSubjectId,
    required String schoolYear,
  }) async {
    await _send(
      'DELETE',
      '/curricula/$curriculumId/selections',
      token,
      query: {
        'curriculum_subject_id': '$curriculumSubjectId',
        'school_year': schoolYear,
      },
    );
  }
}
