import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/students/student_service.dart';

/// PUT /students/{id}  body: {"email": "..."}
/// The app only edits a student's email. The parent folder's authMiddleware
/// verifies the login; ownership is checked in the query.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.put) {
    return Response.json(
      statusCode: 405,
      body: {'status': 'error', 'message': 'Method not allowed'},
    );
  }

  final studentId = int.tryParse(id);

  if (studentId == null || studentId < 1) {
    return Response.json(
      statusCode: 400,
      body: {'status': 'error', 'message': 'Invalid student id'},
    );
  }

  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(403, 'Teacher or administrator access required.');
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return Response.json(
        statusCode: 400,
        body: {'status': 'error', 'message': 'Invalid request body'},
      );
    }

    final student = await StudentService.updateEmail(
      studentId,
      userId: actor.id,
      role: actor.role,
      email: body['email']?.toString(),
    );

    if (student == null) {
      return Response.json(
        statusCode: 404,
        body: {
          'status': 'error',
          'message': 'Student not found or update not permitted.',
        },
      );
    }

    return Response.json(
      body: {'status': 'ok', 'student': student},
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'status': 'error', 'message': 'Invalid JSON request body'},
    );
  } catch (e) {
    // ignore: avoid_print
    print('PUT STUDENT ERROR: $e');
    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': e.toString().replaceFirst('Exception: ', ''),
      },
    );
  }
}
