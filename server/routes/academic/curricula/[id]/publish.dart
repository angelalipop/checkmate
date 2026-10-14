import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    if (context.request.method != HttpMethod.post) {
      return academicMethodNotAllowed();
    }
    final curriculum = await AcademicService.publishCurriculum(
      academicParseId(id, 'curriculum id'),
      academicActorId(context),
    );
    return academicOk({'curriculum': curriculum});
  });
}
