import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/exams/exam_detail_service.dart';
import 'package:server/exams/exam_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final examId = int.tryParse(id);

  if (examId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid exam id',
      },
    );
  }

  switch (context.request.method) {
    case HttpMethod.get:
      return _get(context, examId);
    case HttpMethod.patch:
      return _patch(context, examId);
    default:
      return Response.json(
        statusCode: 405,
        body: {
          'status': 'error',
          'message': 'Method not allowed',
        },
      );
  }
}

Future<Response> _get(RequestContext context, int examId) async {
  final denied = await ExamAccess.guardExam(context, examId);
  if (denied != null) return denied;

  try {
    final exam = await ExamDetailService.getById(examId);

    if (exam == null) {
      return Response.json(
        statusCode: 404,
        body: {
          'status': 'error',
          'message': 'Exam not found',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'exam': exam,
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

Future<Response> _patch(RequestContext context, int examId) async {
  // The parent folder's authMiddleware verifies the JWT and active account.
  final user = context.read<Map<String, dynamic>>();
  final userId = int.tryParse(user['userId']?.toString() ?? '');
  final role = user['role']?.toString() ?? '';

  if (userId == null || (role != 'admin' && role != 'teacher')) {
    return Response.json(
      statusCode: 403,
      body: {'message': 'Permission denied'},
    );
  }

  try {
    final decoded = jsonDecode(await context.request.body());

    if (decoded is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Invalid request body'},
      );
    }

    final title = decoded['title']?.toString().trim() ?? '';

    if (title.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Exam title is required'},
      );
    }

    final exam = await ExamService.update(
      examId,
      userId: userId,
      role: role,
      title: title,
      description: decoded['description']?.toString(),
      instructions: decoded['instructions']?.toString(),
      classId: int.tryParse(decoded['class_id']?.toString() ?? ''),
    );

    if (exam == null) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Exam not found or update not permitted. A class can only be '
              'changed on a draft exam that has no attempts.',
        },
      );
    }

    return Response.json(
      body: {'status': 'ok', 'exam': exam},
    );
  } catch (e) {
    // ignore: avoid_print
    print('PATCH EXAM ERROR: $e');
    return Response.json(
      statusCode: 500,
      body: {'message': e.toString().replaceFirst('Exception: ', '')},
    );
  }
}
