import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');
    final params = context.request.uri.queryParameters;

    switch (context.request.method) {
      case HttpMethod.get:
        final year = int.tryParse(params['year_level'] ?? '');
        final term = int.tryParse(params['term'] ?? '');
        if (year == null || term == null) {
          throw AcademicException('year_level and term are required.');
        }
        final subjects = await AcademicService.listSubjects(
          curriculumId: curriculumId,
          yearLevel: year,
          term: term,
          q: params['q'],
          schoolYear: params['school_year'],
        );
        return academicOk({'subjects': subjects});

      case HttpMethod.post:
        final body = await academicBody(context);
        final subject = await AcademicService.addSubject(curriculumId, body);
        return academicOk({'subject': subject}, statusCode: 201);

      case HttpMethod.delete:
        // Delete Term Subjects: every subject of one year level + semester.
        final year = int.tryParse(params['year_level'] ?? '');
        final term = int.tryParse(params['term'] ?? '');
        if (year == null || term == null) {
          throw AcademicException('year_level and term are required.');
        }
        final removed = await AcademicService.deleteTermSubjects(
          curriculumId: curriculumId,
          yearLevel: year,
          term: term,
          actor: academicActorId(context),
        );
        return academicOk({'deleted': removed});

      default:
        return academicMethodNotAllowed();
    }
  });
}
