import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');

    switch (context.request.method) {
      case HttpMethod.get:
        final electives = await AcademicService.listElectives(curriculumId);
        return academicOk({'electives': electives});

      case HttpMethod.post:
        final body = await academicBody(context);
        final elective = await AcademicService.addElective(curriculumId, body);
        return academicOk({'elective': elective}, statusCode: 201);

      default:
        return academicMethodNotAllowed();
    }
  });
}
