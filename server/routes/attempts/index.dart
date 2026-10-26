import 'package:dart_frog/dart_frog.dart';

import 'package:server/attempts/attempt_service.dart';
import 'package:server/auth/exam_access.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    return _listAttempts(context);
  }

  if (context.request.method == HttpMethod.post) {
    return _createAttempt(context);
  }

  return Response.json(
    statusCode: 405,
    body: {
      'status': 'error',
      'message': 'Method not allowed',
    },
  );
}

Future<Response> _listAttempts(RequestContext context) async {
  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(403, 'Teacher or administrator access required.');
  }

  try {
    final examId = int.tryParse(
      context.request.uri.queryParameters['exam_id'] ?? '',
    );

    final studentId = int.tryParse(
      context.request.uri.queryParameters['student_id'] ?? '',
    );

    // Teachers only receive attempts on exams of their own classes.
    final attempts = await AttemptService.list(
      examId: examId,
      studentId: studentId,
      teacherId: actor.isAdmin ? null : actor.id,
    );

    return Response.json(
      body: {
        'status': 'ok',
        'attempts': attempts,
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

Future<Response> _createAttempt(RequestContext context) async {
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

    final examId = body['exam_id'] is int
        ? body['exam_id'] as int
        : int.tryParse(body['exam_id']?.toString() ?? '');

    final studentId = body['student_id'] is int
        ? body['student_id'] as int
        : int.tryParse(body['student_id']?.toString() ?? '');

    if (examId == null || studentId == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'exam_id and student_id are required',
        },
      );
    }

    // A teacher can only start attempts on exams of their own classes.
    final denied = await ExamAccess.guardExam(context, examId);
    if (denied != null) return denied;

    final attempt = await AttemptService.create(
      examId: examId,
      studentId: studentId,
    );

    return Response.json(
      statusCode: 201,
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
