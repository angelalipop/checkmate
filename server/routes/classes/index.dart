import 'package:dart_frog/dart_frog.dart';

import '../../lib/classes/class_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    try {
      final classes = await ClassService.getAll();

      return Response.json(
        body: {
          'status': 'ok',
          'classes': classes,
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

  return Response.json(
    statusCode: 405,
    body: {
      'status': 'error',
      'message': 'Method not allowed',
    },
  );
}
