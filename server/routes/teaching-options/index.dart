import 'package:dart_frog/dart_frog.dart';

import 'package:server/teachers/teacher_http.dart';
import 'package:server/teachers/teacher_service.dart';

/// GET /teaching-options?academic_subject_id=5&program_id=3   (admin only)
/// The sections of one program (from the Sections catalog) with their owner
/// for that subject, so the app can grey out the ones another teacher
/// already teaches. `subject_id` (an existing subjects row) is still
/// accepted instead of `academic_subject_id`; `program_id`, `year_level`
/// `term` and `school_year` are optional and narrow the sections further.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return methodNotAllowed();
  }

  final params = context.request.uri.queryParameters;
  final subjectId = int.tryParse(params['subject_id'] ?? '');
  final academicSubjectId = int.tryParse(params['academic_subject_id'] ?? '');
  final programId = int.tryParse(params['program_id'] ?? '');
  final yearLevel = int.tryParse(params['year_level'] ?? '');
  final term = int.tryParse(params['term'] ?? '');
  final schoolYear = params['school_year']?.trim();

  if (subjectId == null && academicSubjectId == null) {
    return badRequest('subject_id or academic_subject_id is required');
  }

  try {
    final options = await TeacherService.getTeachingOptions(
      subjectId,
      academicSubjectId: academicSubjectId,
      programId: programId,
      yearLevel: yearLevel,
      term: term,
      schoolYear: schoolYear == null || schoolYear.isEmpty ? null : schoolYear,
    );

    return Response.json(
      body: {'status': 'ok', 'sections': options},
    );
  } catch (e) {
    return teacherErrorResponse(e);
  }
}
