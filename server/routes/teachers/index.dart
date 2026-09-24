import 'package:dart_frog/dart_frog.dart';

import '../../lib/teachers/teacher_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  try {
    final teachers = await TeacherService.getAll();

    return Response.json(
      body: {
        'status': 'ok',
        'teachers': teachers,
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': e.toString(),
      },
    );
  }
}