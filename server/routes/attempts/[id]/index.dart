import 'package:dart_frog/dart_frog.dart';

import 'package:server/attempts/attempt_service.dart';
import 'package:server/auth/exam_access.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final method = context.request.method;
  if (method != HttpMethod.get && method != HttpMethod.delete) {
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

  final denied = await ExamAccess.guardAttempt(context, attemptId);
  if (denied != null) return denied;

  if (method == HttpMethod.delete) {
    try {
      final deleted = await AttemptService.deleteAttempt(attemptId: attemptId);
      if (!deleted) {
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
          'deleted_id': attemptId,
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
