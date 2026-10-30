import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

/// GET /my-subjects
/// The logged-in teacher's own Subject + Section assignments, grouped into
/// one card per subject and academic context.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return mySubjectsMethodNotAllowed();
  }

  try {
    final subjects =
        await MySubjectsService.listSubjects(teacherIdOf(context));

    return Response.json(body: {'status': 'ok', 'subjects': subjects});
  } catch (e) {
    return mySubjectsError(e);
  }
}
