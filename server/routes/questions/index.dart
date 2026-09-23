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
      final questions = await QuestionService.getBySection(sectionId);

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
      final body =
          jsonDecode(await context.request.body()) as Map<String, dynamic>;

      final sectionId = body['section_id'];
      final questionNumber = body['question_number'];
      final questionText = body['question_text'];
      final points = body['points'] ?? 1;
      final choices = body['choices'];
      final correctAnswer = body['correct_answer'];

      if (sectionId is! int ||
          questionNumber is! int ||
          questionNumber < 1 ||
          questionText is! String ||
          questionText.trim().isEmpty ||
          points is! num ||
          points < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'section_id, positive question_number, question_text, '
                'and non-negative points are required',
          },
        );
      }

      if (correctAnswer != null && correctAnswer is! String) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'correct_answer must be a string',
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
        correctAnswer: correctAnswer as String?,
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
