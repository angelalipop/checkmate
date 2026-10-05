import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

/// PUT /teachers/:id/assignments
/// Body: { "assignments": [ { "subject_id", "section",
///                            "school_year", "semester" }, ... ] }
/// Replaces the teacher's whole set of Subject + Section assignments.
/// 409 if any of them already belongs to another teacher.
Future<Response> onRequest(RequestContext context, String id) async {
  final teacherId = parseId(id);

  if (teacherId == null) {
    return badRequest('Invalid teacher id');
  }

  if (context.request.method != HttpMethod.put) {
    return methodNotAllowed();
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return badRequest('Invalid request body');
    }

    final assignments = TeacherService.parseAssignments(body['assignments']);

    if (assignments == null) {
      return badRequest('assignments is required');
    }

    final teacher = await TeacherService.setAssignments(
      id: teacherId,
      assignments: assignments,
    );

    return Response.json(
      body: {'status': 'ok', 'teacher': teacher},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
