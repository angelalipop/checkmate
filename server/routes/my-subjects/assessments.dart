import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

List<int>? _ids(Object? raw) {
  if (raw is List) {
    final out = <int>[];
    for (final v in raw) {
      final n = int.tryParse('$v');
      if (n == null || n < 1) return null;
      out.add(n);
    }
    return out;
  }
  if (raw is String) {
    final out = <int>[];
    for (final part in raw.split(',')) {
      if (part.trim().isEmpty) continue;
      final n = int.tryParse(part.trim());
      if (n == null || n < 1) return null;
      out.add(n);
    }
    return out;
  }
  return null;
}

/// GET  /my-subjects/assessments?class_ids=1,2,3
///      Assessments given to any of those classes (all must be the
///      teacher's own).
/// POST /my-subjects/assessments
///      { "class_ids": [..], "title": "...", "assessment_type": "quiz",
///        "description": "...", "instructions": "..." }
///      Creates a DRAFT assessment. Nothing is created until this is called.
Future<Response> onRequest(RequestContext context) async {
  final teacherId = teacherIdOf(context);

  try {
    switch (context.request.method) {
      case HttpMethod.get:
        final ids = _ids(context.request.uri.queryParameters['class_ids']);
        if (ids == null) return mySubjectsBadRequest('Invalid class_ids');

        final items = await MySubjectsService.listAssessments(teacherId, ids);
        return Response.json(body: {'status': 'ok', 'assessments': items});

      case HttpMethod.post:
        final body = await context.request.json();
        if (body is! Map) return mySubjectsBadRequest('Invalid request body');

        final ids = _ids(body['class_ids']);
        if (ids == null) return mySubjectsBadRequest('Invalid class_ids');

        final created = await MySubjectsService.createAssessment(
          teacherId: teacherId,
          classIds: ids,
          title: body['title']?.toString() ?? '',
          assessmentType: body['assessment_type']?.toString() ?? '',
          description: body['description']?.toString(),
          instructions: body['instructions']?.toString(),
        );

        return Response.json(
          statusCode: 201,
          body: {'status': 'ok', 'assessment': created},
        );

      // ignore: no_default_cases
      default:
        return mySubjectsMethodNotAllowed();
    }
  } on FormatException {
    return mySubjectsBadRequest('Invalid JSON request body');
  } catch (e) {
    return mySubjectsError(e);
  }
}
