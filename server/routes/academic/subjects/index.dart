import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

/// Subject catalog search, used by the Add Subject / Add Elective pickers.
Future<Response> onRequest(RequestContext context) {
  return academicGuard(() async {
    if (context.request.method != HttpMethod.get) {
      return academicMethodNotAllowed();
    }
    final subjects = await AcademicService.searchCatalog(
      context.request.uri.queryParameters['q'],
    );
    return academicOk({'subjects': subjects});
  });
}
