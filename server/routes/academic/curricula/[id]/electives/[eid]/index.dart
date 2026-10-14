import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id, String eid) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');
    final electiveId = academicParseId(eid, 'elective id');

    switch (context.request.method) {
      case HttpMethod.put:
        final body = await academicBody(context);
        final elective = await AcademicService.updateElective(
          curriculumId,
          electiveId,
          body,
        );
        return academicOk({'elective': elective});

      case HttpMethod.delete:
        await AcademicService.deleteElective(
          curriculumId,
          electiveId,
          academicActorId(context),
        );
        return academicOk({'message': 'Elective deleted'});

      default:
        return academicMethodNotAllowed();
    }
  });
}
