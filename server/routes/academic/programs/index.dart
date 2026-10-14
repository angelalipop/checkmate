import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context) {
  return academicGuard(() async {
    switch (context.request.method) {
      case HttpMethod.get:
        final programs = await AcademicService.listPrograms(
          q: context.request.uri.queryParameters['q'],
        );
        return academicOk({'programs': programs});

      case HttpMethod.post:
        final body = await academicBody(context);
        final program = await AcademicService.createProgram(body);
        return academicOk({'program': program}, statusCode: 201);

      default:
        return academicMethodNotAllowed();
    }
  });
}
