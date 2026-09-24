import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../lib/questions/question_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    final sectionId = int.tryParse(
      context.request.uri.queryParameters['section_id'] ?? '',
    );

    if (sectionId == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'section_id query parameter is required',
        },
      );
    }

    try {
      final questions = await QuestionService.getBySection(
        sectionId,
      );

      return Response.json(
        body: {
          'status': 'ok',
          'questions': questions,
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

      final sectionId = int.tryParse(
        body['section_id']?.toString() ?? '',
      );

      final questionNumber = int.tryParse(
        body['question_number']?.toString() ?? '',
      );

      final questionText =
          body['question_text']?.toString().trim();

      final points = num.tryParse(
        body['points']?.toString() ?? '1',
      );

      final choices = body['choices'];

      final correctAnswer =
          body['correct_answer']?.toString().trim();

      if (sectionId == null) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'section_id is required',
          },
        );
      }

      if (questionNumber == null || questionNumber < 1) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'Question number must be at least 1',
          },
        );
      }

      if (questionText == null || questionText.isEmpty) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Question text is required',
          },
        );
      }

      if (points == null || points < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'Question points cannot be negative',
          },
        );
      }

      if (choices != null && choices is! List) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'choices must be an array',
          },
        );
      }

      final question = await QuestionService.create(
        sectionId: sectionId,
        questionNumber: questionNumber,
        questionText: questionText,
        points: points,
        choices: choices,
        correctAnswer:
            correctAnswer == null || correctAnswer.isEmpty
                ? null
                : correctAnswer,
      );

      return Response.json(
        statusCode: 201,
        body: {
          'status': 'ok',
          'question': question,
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