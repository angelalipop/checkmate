import 'package:dart_frog/dart_frog.dart';

import '../../../../../../lib/answers/answer_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
  String answer_id,
) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  final attemptId = int.tryParse(id);
  final answerId = int.tryParse(answer_id);

  if (attemptId == null || answerId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid attempt or answer id',
      },
    );
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Invalid request body',
        },
      );
    }

    final isCorrect = body['is_correct'] is bool
        ? body['is_correct'] as bool
        : null;

    final pointsEarned = body['points_earned'] is num
        ? body['points_earned'] as num
        : num.tryParse(body['points_earned']?.toString() ?? '');

    final recognizedAnswer = body['recognized_answer']?.toString();

    if (isCorrect == null || pointsEarned == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'is_correct and points_earned are required',
        },
      );
    }

    final answer = await AnswerService.verify(
      attemptId: attemptId,
      answerId: answerId,
      isCorrect: isCorrect,
      pointsEarned: pointsEarned,
      recognizedAnswer: recognizedAnswer,
    );

    if (answer == null) {
      return Response.json(
        statusCode: 404,
        body: {
          'status': 'error',
          'message': 'Answer not found',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'answer': answer,
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
