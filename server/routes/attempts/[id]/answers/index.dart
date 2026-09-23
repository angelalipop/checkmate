import 'package:dart_frog/dart_frog.dart';

import '../../../../lib/answers/answer_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
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

    final questionId = body['question_id'] is int
        ? body['question_id'] as int
        : int.tryParse(body['question_id']?.toString() ?? '');

    final rawAnswer = body['answer']?.toString();

    if (questionId == null ||
        rawAnswer == null ||
        rawAnswer.trim().isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'question_id and answer are required',
        },
      );
    }

    final answer = await AnswerService.submit(
      attemptId: attemptId,
      questionId: questionId,
      rawAnswer: rawAnswer,
    );

    return Response.json(
      statusCode: 201,
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
