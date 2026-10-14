import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');

    switch (context.request.method) {
      case HttpMethod.get:
        final curriculum = await AcademicService.getCurriculum(curriculumId);
        return academicOk({'curriculum': curriculum});

      case HttpMethod.put:
        final body = await academicBody(context);
        final curriculum =
            await AcademicService.updateCurriculum(curriculumId, body);
        return academicOk({'curriculum': curriculum});

      case HttpMethod.delete:
        await AcademicService.deleteCurriculum(
          curriculumId,
          academicActorId(context),
        );
        return academicOk({'message': 'Curriculum deleted'});

      default:
        return academicMethodNotAllowed();
    }
  });
}
