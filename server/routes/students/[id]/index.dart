import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/students/student_service.dart';

/// A student's details can be edited ONCE (name, student number, email).
/// After that they are locked. A student cannot be deleted from a section.
Future<Response> onRequest(RequestContext context, String id) async {
  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(403, 'Teacher or administrator access required.');
  }

  switch (context.request.method) {
    case HttpMethod.put:
    case HttpMethod.patch:
      return _edit(context, id);
    case HttpMethod.delete:
      return Response.json(
        statusCode: 403,
        body: {
          'status': 'error',
          'message':
              'Once added, you cannot delete this student from this section.',
        },
      );
    // ignore: no_default_cases
    default:
      return Response.json(
        statusCode: 405,
        body: {'status': 'error', 'message': 'Method not allowed'},
      );
  }
}

Future<Response> _edit(RequestContext context, String idText) async {
  final studentId = int.tryParse(idText);
  if (studentId == null) {
    return ExamAccess.deny(400, 'Invalid student id.');
  }

  try {
    final body = await context.request.json();
    if (body is! Map) {
      return ExamAccess.deny(400, 'Invalid request body');
    }

    final existing = await StudentService.findById(studentId);
    if (existing == null) {
      return ExamAccess.deny(404, 'Student not found.');
    }

    // A teacher can only edit students of a class assigned to them.
    final denied = await ExamAccess.guardClass(
      context,
      existing['class_id']! as int,
    );
    if (denied != null) return denied;

    final student = await StudentService.updateOnce(
      id: studentId,
      studentNumber: body['student_number']?.toString() ?? '',
      firstName: body['first_name']?.toString() ?? '',
      lastName: body['last_name']?.toString() ?? '',
      email: body['email']?.toString(),
    );

    return Response.json(
      body: {
        'status': 'ok',
        'student': student,
      },
    );
  } on StudentEditException catch (e) {
    return ExamAccess.deny(e.statusCode, e.message);
  } catch (e) {
    // ignore: avoid_print
    print('STUDENT EDIT ERROR: $e');
    return ExamAccess.deny(
      500,
      e.toString().replaceFirst('Exception: ', ''),
    );
  }
}
