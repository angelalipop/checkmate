import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final teacherId = parseId(id);

  if (teacherId == null) {
    return badRequest('Invalid teacher id');
  }

  if (context.request.method != HttpMethod.patch) {
    return methodNotAllowed();
  }

  try {
    final body = await context.request.json();

    if (body is! Map || body['is_active'] is! bool) {
      return badRequest('is_active (true/false) is required');
    }

    final teacher = await TeacherService.setActive(
      id: teacherId,
      active: body['is_active'] as bool,
    );

    return Response.json(
      body: {'status': 'ok', 'teacher': teacher},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
