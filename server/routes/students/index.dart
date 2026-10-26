import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/students/student_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(403, 'Teacher or administrator access required.');
  }

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

        // Teachers only receive students of their own classes.
        final students = await StudentService.getAll(
          classId: classId,
          teacherId: actor.isAdmin ? null : actor.id,
        );

        return Response.json(
          body: {
            'status': 'ok',
            'students': students,
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

        final studentNumber =
            body['student_number']?.toString().trim();

        final firstName =
            body['first_name']?.toString().trim();

        final lastName =
            body['last_name']?.toString().trim();

        final email =
            body['email']?.toString().trim();

        if (classId == null) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Class is required',
            },
          );
        }

        if (studentNumber == null ||
            studentNumber.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Student number is required',
            },
          );
        }

        if (firstName == null ||
            firstName.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'First name is required',
            },
          );
        }

        if (lastName == null ||
            lastName.isEmpty) {
          return Response.json(
            statusCode: 400,
            body: {
              'status': 'error',
              'message': 'Last name is required',
            },
          );
        }

        // A teacher can only add students to a class assigned to them.
        final denied = await ExamAccess.guardClass(context, classId);
        if (denied != null) return denied;

        final student = await StudentService.create(
          classId: classId,
          studentNumber: studentNumber,
          firstName: firstName,
          lastName: lastName,
          email: email,
        );

        return Response.json(
          statusCode: 201,
          body: {
            'status': 'ok',
            'student': student,
          },
        );

      // ignore: no_default_cases
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
