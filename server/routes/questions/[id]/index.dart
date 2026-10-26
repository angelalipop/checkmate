import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/questions/question_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
) async {
  final method = context.request.method;

  if (method != HttpMethod.delete && method != HttpMethod.patch) {
    return Response.json(
      statusCode: 405,
      body: {'message': 'Method not allowed'},
    );
  }

  final questionId = int.tryParse(id);

  if (questionId == null || questionId < 1) {
    return Response.json(
      statusCode: 400,
      body: {'message': 'Invalid question ID'},
    );
  }

  // The authentication middleware provides the verified user.
  final user = context.read<Map<String, dynamic>>();

  final userId = int.tryParse(
    user['userId']?.toString() ?? '',
  );

  final role = user['role']?.toString() ?? '';

  if (userId == null) {
    return Response.json(
      statusCode: 401,
      body: {'message': 'Invalid authenticated user'},
    );
  }

  if (role != 'admin' && role != 'teacher') {
    return Response.json(
      statusCode: 403,
      body: {'message': 'Permission denied'},
    );
  }

  if (method == HttpMethod.patch) {
    return _patch(context, questionId, userId: userId, role: role);
  }

  try {
    final deleted = await QuestionService.deleteDraftQuestion(
      questionId,
      userId: userId,
      role: role,
    );

    if (!deleted) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Question not found, permission denied, '
              'or deletion is blocked because the exam '
              'is not a draft or already has attempts.',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'message': 'Question deleted successfully',
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'message': 'Unable to delete question.',
      },
    );
  }
}

Future<Response> _patch(
  RequestContext context,
  int questionId, {
  required int userId,
  required String role,
}) async {
  try {
    final decoded = jsonDecode(await context.request.body());

    if (decoded is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Invalid request body'},
      );
    }

    final text = decoded['question_text']?.toString().trim() ?? '';
    final points = num.tryParse(decoded['points']?.toString() ?? '');
    final correct = decoded['correct_answer']?.toString().trim() ?? '';

    if (text.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Question text is required'},
      );
    }

    if (points == null || points < 0) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'A valid point value is required'},
      );
    }

    if (correct.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Correct answer is required'},
      );
    }

    final question = await QuestionService.updateDraftQuestion(
      questionId,
      userId: userId,
      role: role,
      questionText: text,
      points: points,
      choices: decoded['choices'],
      correctAnswer: correct,
    );

    if (question == null) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Question not found, permission denied, or editing is blocked '
              'because the exam is not a draft or already has attempts.',
        },
      );
    }

    return Response.json(
      body: {'status': 'ok', 'question': question},
    );
  } catch (e) {
    // ignore: avoid_print
    print('PATCH QUESTION ERROR: $e');
    return Response.json(
      statusCode: 500,
      body: {'message': 'Unable to update question.'},
    );
  }
}
