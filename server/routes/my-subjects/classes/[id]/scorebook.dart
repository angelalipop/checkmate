import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

/// GET /my-subjects/classes/{id}/scorebook
/// Students of that one Subject + Section and the assessments given to it.
///
/// DELETE /my-subjects/classes/{id}/scorebook
/// Deletes/resets a student's recorded score for an assessment in that section.
Future<Response> onRequest(RequestContext context, String id) async {
  final method = context.request.method;
  if (method != HttpMethod.get && method != HttpMethod.delete) {
    return mySubjectsMethodNotAllowed();
  }

  final classId = int.tryParse(id);
  if (classId == null || classId < 1) {
    return mySubjectsBadRequest('Invalid section id');
  }

  if (method == HttpMethod.delete) {
    try {
      var body = <String, dynamic>{};
      try {
        final raw = await context.request.json();
        if (raw is Map) {
          body = Map<String, dynamic>.from(raw);
        }
      } catch (_) {
        // Allow query params fallback when DELETE body is empty.
      }

      final q = context.request.uri.queryParameters;
      final examId = int.tryParse('${body['exam_id'] ?? q['exam_id'] ?? ''}');
      final studentId =
          int.tryParse('${body['student_id'] ?? q['student_id'] ?? ''}');
      final attemptId =
          int.tryParse('${body['attempt_id'] ?? q['attempt_id'] ?? ''}');

      if (examId == null || studentId == null) {
        return mySubjectsBadRequest('exam_id and student_id are required');
      }

      await MySubjectsService.deleteScore(
        teacherId: teacherIdOf(context),
        classId: classId,
        examId: examId,
        studentId: studentId,
        attemptId: attemptId,
      );

      return Response.json(body: {'status': 'ok'});
    } catch (e) {
      return mySubjectsError(e);
    }
  }

  try {
    final book = await MySubjectsService.scorebook(
      teacherIdOf(context),
      classId,
    );

    return Response.json(body: {'status': 'ok', ...book});
  } catch (e) {
    return mySubjectsError(e);
  }
}
