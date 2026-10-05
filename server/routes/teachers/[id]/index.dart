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
          name: body['name']?.toString() ?? '',
          email: body['email']?.toString() ?? '',
          username: body['username']?.toString() ?? '',
          // null = leave assignments untouched; [] = remove them all.
          assignments: TeacherService.parseAssignments(body['assignments']),
        );

        return Response.json(
          body: {'status': 'ok', 'teacher': teacher},
        );

      case HttpMethod.delete:
        await TeacherService.delete(teacherId);

        return Response.json(
          body: {'status': 'ok', 'message': 'Teacher deleted'},
        );

      default:
        return methodNotAllowed();
    }
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
