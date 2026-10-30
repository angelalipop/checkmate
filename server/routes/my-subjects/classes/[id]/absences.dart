import 'package:dart_frog/dart_frog.dart';

import 'package:server/my_subjects/my_subjects_http.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

/// PUT /my-subjects/classes/{id}/absences
/// { "exam_id": 1, "student_id": 2, "absent": true }
/// Records (or removes) the teacher's explicit confirmation that a student
/// was absent for an assessment.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.put) {
    return mySubjectsMethodNotAllowed();
  }

  final classId = int.tryParse(id);
  if (classId == null || classId < 1) {
    return mySubjectsBadRequest('Invalid section id');
  }

  try {
    final body = await context.request.json();
    if (body is! Map) return mySubjectsBadRequest('Invalid request body');

    final examId = int.tryParse('${body['exam_id']}');
    final studentId = int.tryParse('${body['student_id']}');
    final absent = body['absent'];

    if (examId == null || studentId == null || absent is! bool) {
      return mySubjectsBadRequest(
        'exam_id, student_id and absent (true/false) are required',
      );
    }

    await MySubjectsService.setAbsence(
      teacherId: teacherIdOf(context),
      classId: classId,
      examId: examId,
      studentId: studentId,
      absent: absent,
    );

    return Response.json(body: {'status': 'ok'});
  } on FormatException {
    return mySubjectsBadRequest('Invalid JSON request body');
  } catch (e) {
    return mySubjectsError(e);
  }
}
