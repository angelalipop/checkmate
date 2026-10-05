import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final teacherId = parseId(id);

  if (teacherId == null) {
    return badRequest('Invalid teacher id');
  }

  if (context.request.method != HttpMethod.post) {
    return methodNotAllowed();
  }

  try {
    final password = await TeacherService.resetPassword(teacherId);

    // The only place a plaintext password leaves the server: once, here.
    return Response.json(
      headers: {'Cache-Control': 'no-store'},
      body: {'status': 'ok', 'temporary_password': password},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
