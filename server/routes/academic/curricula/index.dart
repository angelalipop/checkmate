import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_exception.dart';
import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context) {
  return academicGuard(() async {
    switch (context.request.method) {
      case HttpMethod.get:
        final params = context.request.uri.queryParameters;
        final programId = int.tryParse(params['program_id'] ?? '');
        if (programId == null) {
          throw AcademicException('program_id is required.');
        }
        final curricula = await AcademicService.listCurricula(
          programId: programId,
          status: params['status'],
        );
        return academicOk({'curricula': curricula});

      case HttpMethod.post:
        final body = await academicBody(context);
        final curriculum = await AcademicService.createCurriculum(
          body,
          academicActorId(context),
        );
        return academicOk({'curriculum': curriculum}, statusCode: 201);

      default:
        return academicMethodNotAllowed();
    }
  });
}
