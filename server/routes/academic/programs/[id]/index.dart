import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    final programId = academicParseId(id, 'program id');

    switch (context.request.method) {
      case HttpMethod.put:
        final body = await academicBody(context);
        final program = await AcademicService.updateProgram(programId, body);
        return academicOk({'program': program});

      case HttpMethod.delete:
        await AcademicService.deleteProgram(
          programId,
          academicActorId(context),
        );
        return academicOk({'message': 'Program deleted'});

      default:
        return academicMethodNotAllowed();
    }
  });
}
