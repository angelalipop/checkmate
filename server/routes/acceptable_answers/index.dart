import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../lib/acceptable_answers/acceptable_answer_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    final questionId = int.tryParse(
      context.request.uri.queryParameters['question_id'] ?? '',
    );

    if (questionId == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'question_id query parameter is required',
        },
      );
    }

    try {
      final answers =
          await AcceptableAnswerService.getByQuestion(
        questionId,
      );

      return Response.json(
        body: {
          'status': 'ok',
          'answers': answers,
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

  if (context.request.method == HttpMethod.post) {
    try {
      final decodedBody = jsonDecode(
        await context.request.body(),
      );

      if (decodedBody is! Map<String, dynamic>) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Invalid request body',
          },
        );
      }

      final body = decodedBody;

      final questionId = int.tryParse(
        body['question_id']?.toString() ?? '',
      );

      final answer = body['answer']?.toString().trim();

      if (questionId == null) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'question_id is required',
          },
        );
      }

      if (answer == null || answer.isEmpty) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Answer is required',
          },
        );
      }

      final acceptableAnswer =
          await AcceptableAnswerService.create(
        questionId: questionId,
        answer: answer,
      );

      return Response.json(
        statusCode: 201,
        body: {
          'status': 'ok',
          'answer': acceptableAnswer,
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