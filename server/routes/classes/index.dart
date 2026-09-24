import 'package:dart_frog/dart_frog.dart';

import '../../lib/classes/class_service.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    switch (context.request.method) {
      case HttpMethod.get:
        final classes = await ClassService.getAll();

        return Response.json(
          body: {
            'status': 'ok',
            'classes': classes,
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

        final subjectId = int.tryParse(
          body['subject_id']?.toString() ?? '',
        );

        final teacherId = int.tryParse(
          body['teacher_id']?.toString() ?? '',
        );

        final section = body['section']?.toString().trim();

        final schoolYear =
            body['school_year']?.toString().trim();

        final semester =
            body['semester']?.toString().trim();

        if (subjectId == null) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Subject is required',
            },
          );
        }

        if (teacherId == null) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Teacher is required',
            },
          );
        }

        if (section == null || section.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Section is required',
            },
          );
        }

        final newClass = await ClassService.create(
          subjectId: subjectId,
          teacherId: teacherId,
          section: section,
          schoolYear:
              schoolYear == null || schoolYear.isEmpty
                  ? null
                  : schoolYear,
          semester:
              semester == null || semester.isEmpty
                  ? null
                  : semester,
        );

        return Response.json(
          statusCode: 201,
          body: {
            'status': 'ok',
            'class': newClass,
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