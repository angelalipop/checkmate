import 'package:dart_frog/dart_frog.dart';

import '../../lib/students/student_service.dart';

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

        final students = await StudentService.getAll(
          classId: classId,
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