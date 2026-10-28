import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

/// GET /teaching-options/subjects?program_id=3   (admin only)
/// Subjects of that program's published curriculum from Academic Management.
/// A subject shared by several programs is returned for each of them.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return methodNotAllowed();
  }

  final programId = int.tryParse(
    context.request.uri.queryParameters['program_id'] ?? '',
  );

  if (programId == null) {
    return badRequest('program_id is required');
  }

  try {
    final subjects = await TeacherService.getProgramSubjects(programId);

    return Response.json(
      body: {'status': 'ok', 'subjects': subjects},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
