import 'package:dart_frog/dart_frog.dart';

import '../../../lib/attempts/attempt_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  final attemptId = int.tryParse(id);

  if (attemptId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid attempt id',
      },
    );
  }

  try {
    final attempt = await AttemptService.getById(
      attemptId: attemptId,
    );

    if (attempt == null) {
      return Response.json(
        statusCode: 404,
        body: {
          'status': 'error',
          'message': 'Attempt not found',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'attempt': attempt,
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
