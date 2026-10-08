import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    switch (context.request.method) {
      case HttpMethod.get:
        final teachers = await TeacherService.getAll();

        return Response.json(
          body: {'status': 'ok', 'teachers': teachers},
        );

      case HttpMethod.post:
        final body = await context.request.json();

        if (body is! Map) {
          return badRequest('Invalid request body');
        }

        final teacher = await TeacherService.create(
          teacherIdNo: body['teacher_id_no']?.toString() ?? '',
          firstName: body['first_name']?.toString() ?? '',
          middleName: body['middle_name']?.toString() ?? '',
          lastName: body['last_name']?.toString() ?? '',
          department: body['department']?.toString() ?? '',
          temporaryPassword:
              body['temporary_password']?.toString() ?? '',
          assignments:
              TeacherService.parseAssignments(body['assignments']) ?? [],
        );

        return Response.json(
          statusCode: 201,
          body: {'status': 'ok', 'teacher': teacher},
        );

      default:
        return methodNotAllowed();
    }
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
