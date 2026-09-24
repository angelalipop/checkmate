import 'package:dart_frog/dart_frog.dart';

import '../../lib/exams/exam_service.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    switch (context.request.method) {
      case HttpMethod.get:
        final classIdText =
            context.request.uri.queryParameters['class_id'];

        final classId = classIdText == null ||
                classIdText.isEmpty
            ? null
            : int.tryParse(classIdText);

        if (classIdText != null &&
            classIdText.isNotEmpty &&
            classId == null) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Invalid class_id',
            },
          );
        }

        final exams = await ExamService.getAll(
          classId: classId,
        );

        return Response.json(
          body: {
            'status': 'ok',
            'exams': exams,
          },
        );

      case HttpMethod.post:
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

        final classId = int.tryParse(
          body['class_id']?.toString() ?? '',
        );

        final title =
            body['title']?.toString().trim();

        final description =
            body['description']?.toString().trim();

        final instructions =
            body['instructions']?.toString().trim();

        final status =
            body['status']?.toString().trim();

        if (classId == null) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Class is required',
            },
          );
        }

        if (title == null || title.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Exam title is required',
            },
          );
        }

        if (status != null &&
            status.isNotEmpty &&
            ![
              'draft',
              'published',
              'archived',
            ].contains(status.toLowerCase())) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message':
                  'Invalid exam status. '
                  'Use draft, published, or archived.',
            },
          );
        }

        final exam = await ExamService.create(
          classId: classId,
          title: title,
          description:
              description?.isEmpty == true
                  ? null
                  : description,
          instructions:
              instructions?.isEmpty == true
                  ? null
                  : instructions,
          status: status?.isEmpty == true
              ? null
              : status,
        );

        return Response.json(
          statusCode: 201,
          body: {
            'status': 'ok',
            'exam': exam,
          },
        );

      default:
        return Response.json(
          statusCode: 405,
          body: {
            'status': 'error',
            'message': 'Method not allowed',
          },
        );
    }
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