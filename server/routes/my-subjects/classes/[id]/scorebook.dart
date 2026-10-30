import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

/// GET /my-subjects/classes/{id}/scorebook
/// Students of that one Subject + Section and the assessments given to it.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return mySubjectsMethodNotAllowed();
  }

  final classId = int.tryParse(id);
  if (classId == null || classId < 1) {
    return mySubjectsBadRequest('Invalid section id');
  }

  try {
    final book = await MySubjectsService.scorebook(
      teacherIdOf(context),
      classId,
    );

    return Response.json(body: {'status': 'ok', ...book});
  } catch (e) {
    return mySubjectsError(e);
  }
}
