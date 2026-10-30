import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_service.dart';

/// The verified teacher id from the login token (set by authMiddleware).
int teacherIdOf(RequestContext context) {
  final user = context.read<Map<String, dynamic>>();
  return user['userId'] as int;
}

Response mySubjectsError(Object error) {
  if (error is MySubjectsException) {
    return Response.json(
      statusCode: error.statusCode,
      body: {'status': 'error', 'message': error.message},
    );
  }

  // ignore: avoid_print
  print('MY SUBJECTS ROUTE ERROR: $error');

  return Response.json(
    statusCode: 500,
    body: {'status': 'error', 'message': 'Internal server error'},
  );
}

Response mySubjectsMethodNotAllowed() {
  return Response.json(
    statusCode: 405,
    body: {'status': 'error', 'message': 'Method not allowed'},
  );
}

Response mySubjectsBadRequest(String message) {
  return Response.json(
    statusCode: 400,
    body: {'status': 'error', 'message': message},
  );
}
