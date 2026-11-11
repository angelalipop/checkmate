import 'package:dart_frog/dart_frog.dart';
import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final cid = int.tryParse(id);
  if (cid == null || cid < 1) return mySubjectsBadRequest('Invalid section id');
  try {
    final teacher = teacherIdOf(context);
    switch (context.request.method) {
      case HttpMethod.get:
        return Response.json(
          body: {
            'status': 'ok',
            'preferences': await MySubjectsService.gradingPreferences(
              teacher,
              cid,
            ),
          },
        );
      case HttpMethod.put:
        final body = await context.request.json();
        if (body is! Map<String, dynamic>)
          return mySubjectsBadRequest('Invalid preferences');
        return Response.json(
          body: {
            'status': 'ok',
            'preferences': await MySubjectsService.saveGradingPreferences(
              teacher,
              cid,
              body,
            ),
          },
        );
      default:
        return mySubjectsMethodNotAllowed();
    }
  } catch (e) {
    return mySubjectsError(e);
  }
}
