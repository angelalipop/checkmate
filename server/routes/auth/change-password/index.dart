import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/auth_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'status': 'error', 'message': 'Method not allowed'},
    );
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return Response.json(
        statusCode: 400,
        body: {'status': 'error', 'message': 'Invalid request body'},
      );
    }

    final user = context.read<Map<String, dynamic>>();

    await AuthService.changePassword(
      userId: user['userId'] as int,
      currentPassword: body['current_password']?.toString() ?? '',
      newPassword: body['new_password']?.toString() ?? '',
    );

    return Response.json(
      body: {'status': 'ok', 'message': 'Password changed'},
    );
  } on AuthException catch (e) {
    return Response.json(
      statusCode: e.statusCode,
      body: {'status': 'error', 'message': e.message},
    );
  } catch (e) {
    // ignore: avoid_print
    print('CHANGE PASSWORD ERROR: $e');

    return Response.json(
      statusCode: 500,
      body: {'status': 'error', 'message': 'Internal server error'},
    );
  }
}
