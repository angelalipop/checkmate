import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/students/student_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(
      403,
      'Teacher or administrator access required.',
    );
  }

  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Invalid request body.',
        },
      );
    }

    final section = body['section']?.toString().trim() ?? '';
    final rawUpdates = body['updates'];

    if (section.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Section is required.',
        },
      );
    }

    if (rawUpdates is! List || rawUpdates.any((item) => item is! Map)) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Invalid student updates.',
        },
      );
    }

    final updates = rawUpdates
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();

    final result = await StudentService.updateEmailsForSection(
      section: section,
      updates: updates,
      teacherId: actor.isAdmin ? null : actor.id,
    );

    return Response.json(
      body: {
        'status': 'ok',
        ...result,
      },
    );
  } on StudentEmailException catch (e) {
    return Response.json(
      statusCode: e.statusCode,
      body: {
        'status': 'error',
        'message': e.message,
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': 'Unable to save student emails.',
      },
    );
  }
}
