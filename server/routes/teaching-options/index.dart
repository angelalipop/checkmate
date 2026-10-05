import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

/// GET /teaching-options?subject_id=5   (admin only)
/// Every known section with its owner for that subject, so the app can
/// grey out the ones another teacher already teaches.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return methodNotAllowed();
  }

  final subjectId = int.tryParse(
    context.request.uri.queryParameters['subject_id'] ?? '',
  );

  if (subjectId == null) {
    return badRequest('subject_id is required');
  }

  try {
    final options = await TeacherService.getTeachingOptions(subjectId);

    return Response.json(
      body: {'status': 'ok', 'sections': options},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
