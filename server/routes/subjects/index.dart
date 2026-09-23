import 'package:dart_frog/dart_frog.dart';

import '../../lib/subjects/subject_service.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    switch (context.request.method) {
      case HttpMethod.get:
        final subjects = await SubjectService.getAll();

        return Response.json(
          body: {
            'status': 'ok',
            'subjects': subjects,
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

        final name = body['name']?.toString().trim();

        if (name == null || name.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Subject name is required',
            },
          );
        }

        final code = body['code']?.toString();

        final subject = await SubjectService.create(
          name: name,
          code: code,
        );

        return Response.json(
          statusCode: 201,
          body: {
            'status': 'ok',
            'subject': subject,
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
