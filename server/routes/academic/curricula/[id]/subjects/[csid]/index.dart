import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id, String csid) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');
    final subjectId = academicParseId(csid, 'subject id');

    switch (context.request.method) {
      case HttpMethod.put:
        final body = await academicBody(context);
        final subject = await AcademicService.updateSubject(
          curriculumId,
          subjectId,
          body,
          actor: academicActorId(context),
        );
        return academicOk({'subject': subject});

      case HttpMethod.delete:
        await AcademicService.deleteSubject(
          curriculumId,
          subjectId,
          academicActorId(context),
        );
        return academicOk({'message': 'Subject deleted'});

      default:
        return academicMethodNotAllowed();
    }
  });
}
