import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_identity.dart';

Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(
      statusCode: 405,
      headers: {'allow': 'GET'},
    );
  }

  return Response.json(
    body: {
      'status': 'ok',
      'departments': TeacherIdentity.departments,
    },
  );
}
