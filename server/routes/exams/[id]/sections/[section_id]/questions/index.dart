import 'package:dart_frog/dart_frog.dart';

import '../../../../../../lib/exams/question_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
  String section_id,
) async {
  final examId = int.tryParse(id);
  final sectionId = int.tryParse(section_id);

  if (examId == null || sectionId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid exam or section id',
      },
    );
  }

  if (context.request.method == HttpMethod.get) {
    try {
      final questions = await QuestionService.getAll(
        sectionId: sectionId,
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

      final questionNumber = body['question_number'] is int
          ? body['question_number'] as int
          : int.tryParse(
              body['question_number']?.toString() ?? '',
            );

      final questionText = body['question_text']?.toString();

      final points = body['points'] is num
          ? body['points'] as num
          : num.tryParse(
              body['points']?.toString() ?? '',
            );

      final correctAnswer = body['correct_answer']?.toString();
      final choices = body['choices'];

      if (questionNumber == null ||
          questionNumber < 1 ||
          questionText == null ||
          questionText.trim().isEmpty ||
          points == null ||
          points < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'question_number, question_text, and valid points are required',
          },
        );
      }

      final question = await QuestionService.create(
        sectionId: sectionId,
        questionNumber: questionNumber,
        questionText: questionText,
        points: points,
        choices: choices,
        correctAnswer: correctAnswer,
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
