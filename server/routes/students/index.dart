import 'package:dart_frog/dart_frog.dart';

import '../../lib/students/student_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    try {
      final classId =
          int.tryParse(context.request.uri.queryParameters['class_id'] ?? '');

      final students = await StudentService.getAll(
        classId: classId,
      );

      return Response.json(
        body: {
          'status': 'ok',
          'students': students,
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

      final studentNumber = body['student_number']?.toString();
      final firstName = body['first_name']?.toString();
      final lastName = body['last_name']?.toString();
      final email = body['email']?.toString();

      if (classId == null ||
          studentNumber == null ||
          studentNumber.trim().isEmpty ||
          firstName == null ||
          firstName.trim().isEmpty ||
          lastName == null ||
          lastName.trim().isEmpty) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'class_id, student_number, first_name, and last_name are required',
          },
        );
      }

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
