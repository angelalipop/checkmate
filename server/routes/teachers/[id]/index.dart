import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final teacherId = parseId(id);

  if (teacherId == null) {
    return badRequest('Invalid teacher id');
  }

  try {
    switch (context.request.method) {
      case HttpMethod.put:
        final body = await context.request.json();

        if (body is! Map) {
          return badRequest('Invalid request body');
        }

        final teacher = await TeacherService.update(
          id: teacherId,
          teacherIdNo: body['teacher_id_no']?.toString() ?? '',
          firstName: body['first_name']?.toString() ?? '',
          middleName: body['middle_name']?.toString() ?? '',
          lastName: body['last_name']?.toString() ?? '',
          department: body['department']?.toString() ?? '',
          isActive: body.containsKey('is_active')
              ? body['is_active'] == true
              : null,
          // null = leave assignments untouched; [] = remove them all.
          assignments: TeacherService.parseAssignments(body['assignments']),
        );

        return Response.json(
          body: {'status': 'ok', 'teacher': teacher},
        );

      case HttpMethod.delete:
        final releasedAssignments =
            await TeacherService.delete(teacherId);

        return Response.json(
          body: {
            'status': 'ok',
            'message': 'Teacher deleted',
            'released_assignments': releasedAssignments,
          },
        );

      default:
        return methodNotAllowed();
    }
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
