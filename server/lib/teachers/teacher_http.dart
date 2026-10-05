import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_service.dart';

/// Turns a thrown error into a JSON response. Internal errors are logged
/// on the server and never leaked to the client.
Response teacherErrorResponse(Object error) {
  if (error is TeacherException) {
    return Response.json(
      statusCode: error.statusCode,
      body: {'status': 'error', 'message': error.message},
    );
  }

  // ignore: avoid_print
  print('TEACHER ROUTE ERROR: $error');

  return Response.json(
    statusCode: 500,
    body: {'status': 'error', 'message': 'Internal server error'},
  );
}

Response methodNotAllowed() {
  return Response.json(
    statusCode: 405,
    body: {'status': 'error', 'message': 'Method not allowed'},
  );
}

Response badRequest(String message) {
  return Response.json(
    statusCode: 400,
    body: {'status': 'error', 'message': message},
  );
}

int? parseId(String raw) => int.tryParse(raw);
