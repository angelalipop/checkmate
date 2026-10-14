import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

/// Lists what would stop this curriculum from being published.
Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    if (context.request.method != HttpMethod.get) {
      return academicMethodNotAllowed();
    }
    final issues = await AcademicService.validateCurriculum(
      academicParseId(id, 'curriculum id'),
    );
    return academicOk({'valid': issues.isEmpty, 'issues': issues});
  });
}
