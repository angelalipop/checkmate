import 'package:dart_frog/dart_frog.dart';

import '../../../lib/exams/exam_detail_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  final examId = int.tryParse(id);

  if (examId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid exam id',
      },
    );
  }

  try {
    final exam = await ExamDetailService.getById(examId);

    if (exam == null) {
      return Response.json(
        statusCode: 404,
        body: {
          'status': 'error',
          'message': 'Exam not found',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'exam': exam,
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': e.toString(),
      },
    );
  }
}
