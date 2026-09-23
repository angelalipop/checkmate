import 'package:dart_frog/dart_frog.dart';

import '../../lib/exams/exam_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    try {
      final classId = int.tryParse(
        context.request.uri.queryParameters['class_id'] ?? '',
      );

      final exams = await ExamService.getAll(
        classId: classId,
      );

      return Response.json(
        body: {
          'status': 'ok',
          'exams': exams,
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

      final classId = body['class_id'] is int
          ? body['class_id'] as int
          : int.tryParse(body['class_id']?.toString() ?? '');

      final title = body['title']?.toString();
      final description = body['description']?.toString();
      final instructions = body['instructions']?.toString();
      final status = body['status']?.toString();

      if (classId == null ||
          title == null ||
          title.trim().isEmpty) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'class_id and title are required',
          },
        );
      }

      final exam = await ExamService.create(
        classId: classId,
        title: title,
        description: description,
        instructions: instructions,
        status: status,
      );

      return Response.json(
        statusCode: 201,
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

  return Response.json(
    statusCode: 405,
    body: {
      'status': 'error',
      'message': 'Method not allowed',
    },
  );
}
