import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/auth/exam_access.dart';
import 'package:server/questions/question_service.dart';

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _getQuestions(context);

    case HttpMethod.post:
      return _createQuestion(context);

    default:
      return Response.json(
        statusCode: 405,
        body: {'message': 'Method not allowed'},
      );
  }
}

// GET /questions?section_id=1
Future<Response> _getQuestions(RequestContext context) async {
  final sectionId = int.tryParse(
    context.request.uri.queryParameters['section_id'] ?? '',
  );

  if (sectionId == null || sectionId < 1) {
    return Response.json(
      statusCode: 400,
      body: {'message': 'Valid section_id is required'},
    );
  }

  try {
    final denied = await ExamAccess.guardSection(context, sectionId);
    if (denied != null) return denied;

    final questions = await QuestionService.getBySection(sectionId);

    return Response.json(
      body: {'questions': questions},
    );
  } catch (e) {
    print('GET QUESTIONS ERROR: $e');

    return Response.json(
      statusCode: 500,
      body: {'message': 'Failed to load questions'},
    );
  }
}

// POST /questions
Future<Response> _createQuestion(RequestContext context) async {
  try {
    final decoded = jsonDecode(await context.request.body());

    if (decoded is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Invalid request body'},
      );
    }

    final sectionId = int.tryParse(
      decoded['section_id']?.toString() ?? '',
    );

    final questionNumber = int.tryParse(
      decoded['question_number']?.toString() ?? '',
    );

    final questionText = decoded['question_text']?.toString() ?? '';

    final points = num.tryParse(
      decoded['points']?.toString() ?? '',
    );

    if (sectionId == null ||
        sectionId < 1 ||
        questionNumber == null ||
        questionNumber < 1 ||
        questionText.trim().isEmpty ||
        points == null ||
        points < 0) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Invalid question data'},
      );
    }

    final denied = await ExamAccess.guardSection(context, sectionId);
    if (denied != null) return denied;

    final question = await QuestionService.create(
      sectionId: sectionId,
      questionNumber: questionNumber,
      questionText: questionText,
      points: points,
      choices: decoded['choices'],
      correctAnswer: decoded['correct_answer']?.toString(),
    );

    return Response.json(
      statusCode: 201,
      body: {'question': question},
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'message': 'Invalid JSON request body'},
    );
  } catch (e) {
    print('CREATE QUESTION ERROR: $e');

    return Response.json(
      statusCode: 500,
      body: {'message': 'Failed to create question'},
    );
  }
}
