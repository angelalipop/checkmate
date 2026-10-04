import 'package:dart_frog/dart_frog.dart';

import 'package:server/exams/question_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
  String sectionId,
) async {
  // Convert the route parameters from String to int.
  final examId = int.tryParse(id);
  final parsedSectionId = int.tryParse(sectionId);

  // Make sure both IDs are valid integers.
  if (examId == null || parsedSectionId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid exam or section id',
      },
    );
  }

  // GET: Retrieve all questions belonging to this section.
  if (context.request.method == HttpMethod.get) {
    try {
      final questions = await QuestionService.getAll(
        sectionId: parsedSectionId,
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

  // POST: Create a new question for this section.
  if (context.request.method == HttpMethod.post) {
    try {
      final body = await context.request.json();

      if (body is! Map<String, dynamic>) {
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

      // Validate required question information.
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
        sectionId: parsedSectionId,
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

  // Reject HTTP methods other than GET and POST.
  return Response.json(
    statusCode: 405,
    body: {
      'status': 'error',
      'message': 'Method not allowed',
    },
  );
}
