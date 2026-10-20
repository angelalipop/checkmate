import 'package:dart_frog/dart_frog.dart';
import 'package:server/questions/question_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
) async {
  if (context.request.method != HttpMethod.delete) {
    return Response.json(
      statusCode: 405,
      body: {'message': 'Method not allowed'},
    );
  }

  final questionId = int.tryParse(id);

  if (questionId == null || questionId < 1) {
    return Response.json(
      statusCode: 400,
      body: {'message': 'Invalid question ID'},
    );
  }

  // The authentication middleware provides the verified user.
  final user = context.read<Map<String, dynamic>>();

  final userId = int.tryParse(
    user['userId']?.toString() ?? '',
  );

  final role = user['role']?.toString() ?? '';

  if (userId == null) {
    return Response.json(
      statusCode: 401,
      body: {'message': 'Invalid authenticated user'},
    );
  }

  if (role != 'admin' && role != 'teacher') {
    return Response.json(
      statusCode: 403,
      body: {'message': 'Permission denied'},
    );
  }

  try {
    final deleted = await QuestionService.deleteDraftQuestion(
      questionId,
      userId: userId,
      role: role,
    );

    if (!deleted) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Question not found, permission denied, '
              'or deletion is blocked because the exam '
              'is not a draft or already has attempts.',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'message': 'Question deleted successfully',
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'message': 'Unable to delete question.',
      },
    );
  }
}