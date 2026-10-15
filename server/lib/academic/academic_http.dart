import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_service.dart';

/// Runs a route body and turns any thrown error into a JSON response.
/// Internal errors are logged on the server and never leaked to the client.
Future<Response> academicGuard(Future<Response> Function() body) async {
  try {
    return await body();
  } catch (e) {
    return academicErrorResponse(e);
  }
}

Response academicErrorResponse(Object error) {
  final mapped = AcademicService.mapError(error);

  if (mapped is AcademicException) {
    return Response.json(
      statusCode: mapped.statusCode,
      body: {
        'status': 'error',
        'message': mapped.message,
        if (mapped.issues.isNotEmpty) 'issues': mapped.issues,
      },
    );
  }

  // ignore: avoid_print
  print('ACADEMIC ROUTE ERROR: $error');

  return Response.json(
    statusCode: 500,
    body: {'status': 'error', 'message': 'Internal server error'},
  );
}

Response academicMethodNotAllowed() {
  return Response.json(
    statusCode: 405,
    body: {'status': 'error', 'message': 'Method not allowed'},
  );
}

Response academicOk(Map<String, dynamic> body, {int statusCode = 200}) {
  return Response.json(
    statusCode: statusCode,
    body: {'status': 'ok', ...body},
  );
}

/// The id of the signed-in administrator (set by authMiddleware).
int? academicActorId(RequestContext context) {
  final user = context.read<Map<String, dynamic>>();
  return int.tryParse(user['userId']?.toString() ?? '');
}

int academicParseId(String raw, String label) {
  final id = int.tryParse(raw);
  if (id == null || id <= 0) {
    throw AcademicException('Invalid $label.'); 
  }
  return id;
}

Future<Map<String, dynamic>> academicBody(RequestContext context) async {
  final Object? body;
  try {
    body = await context.request.json();
  } catch (_) {
    throw AcademicException('Invalid request body.');
  }
  if (body is! Map) {
    throw AcademicException('Invalid request body.');
  }
  return Map<String, dynamic>.from(body);
}
