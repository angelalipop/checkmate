import 'package:dart_frog/dart_frog.dart';

import 'package:server/academic/academic_http.dart';
import 'package:server/academic/academic_service.dart';

/// The elective finalized for a slot in a school year.
///   GET    ?school_year=2025-2026
///   PUT    {curriculum_subject_id, elective_id, school_year}
///   DELETE ?curriculum_subject_id=&school_year=
Future<Response> onRequest(RequestContext context, String id) {
  return academicGuard(() async {
    final curriculumId = academicParseId(id, 'curriculum id');
    final params = context.request.uri.queryParameters;

    switch (context.request.method) {
      case HttpMethod.get:
        final selections = await AcademicService.listSelections(
          curriculumId: curriculumId,
          schoolYear: params['school_year'] ?? '',
        );
        return academicOk({'selections': selections});

      case HttpMethod.put:
        final body = await academicBody(context);
        final selection = await AcademicService.setSelection(
          curriculumId,
          body,
          academicActorId(context),
        );
        return academicOk({'selection': selection});

      case HttpMethod.delete:
        final csId = int.tryParse(params['curriculum_subject_id'] ?? '');
        if (csId == null) {
          throw AcademicException('curriculum_subject_id is required.');
        }
        await AcademicService.clearSelection(
          curriculumId: curriculumId,
          curriculumSubjectId: csId,
          schoolYear: params['school_year'] ?? '',
          actor: academicActorId(context),
        );
        return academicOk({'message': 'Elective choice cleared'});

      default:
        return academicMethodNotAllowed();
    }
  });
}
