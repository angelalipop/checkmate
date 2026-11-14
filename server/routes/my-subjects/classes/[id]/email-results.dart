import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/exam_access.dart';
import 'package:server/email/result_email_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed.',
      },
    );
  }

  final actor = ExamActor.fromContext(context);

  if (actor == null) {
    return ExamAccess.deny(
      403,
      'You are not authorized to send exam results.',
    );
  }

  final classId = int.tryParse(id);

  if (classId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid class ID.',
      },
    );
  }

  final accessResponse = await ExamAccess.guardClass(
    context,
    classId,
  );

  if (accessResponse != null) {
    return accessResponse;
  }

  try {
    final requestBody = await context.request.json();

    if (requestBody is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Invalid request body.',
        },
      );
    }

    final examId = int.tryParse(
      requestBody['exam_id']?.toString() ?? '',
    );

    if (examId == null || examId <= 0) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'A valid exam_id is required.',
        },
      );
    }

    final result = await ResultEmailService.sendExamResults(
      actorId: actor.id,
      isAdmin: actor.isAdmin,
      classId: classId,
      examId: examId,
    );

    return Response.json(
      body: {
        'status': 'success',
        'message': 'Exam result email process completed.',
        'data': result,
      },
    );
  } on ResultEmailException catch (e) {
    return Response.json(
      statusCode: e.statusCode,
      body: {
        'status': 'error',
        'message': e.message,
      },
    );
  } catch (e, stackTrace) {
    print('EMAIL RESULTS ERROR: $e');
    print('EMAIL RESULTS STACK TRACE: $stackTrace');

    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': 'Failed to process exam result emails.',
      },
    );
  }
}
