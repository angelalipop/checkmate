import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/auth_service.dart';
import 'package:server/auth/jwt_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {
        'status': 'error',
        'message': 'Method not allowed',
      },
    );
  }

  try {
    final body = await context.request.json();

    if (body is! Map) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Invalid request body',
        },
      );
    }

    // The app sends the field as "email"; it may hold an email OR a
    // username. "username" is also accepted.
    final identifier =
        (body['email'] ?? body['username'])?.toString();
    final password = body['password']?.toString();

    if (identifier == null ||
        identifier.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Email/username and password are required',
        },
      );
    }

    final user = await AuthService.login(
      identifier: identifier,
      password: password,
    );

    if (user == null) {
      return Response.json(
        statusCode: 401,
        body: {
          'status': 'error',
          'message': 'Invalid email/username or password',
        },
      );
    }

    // Only reached with the correct password, so this does not reveal
    // which accounts exist to someone guessing.
    if (user['is_active'] != true) {
      return Response.json(
        statusCode: 403,
        body: {
          'status': 'error',
          'message':
              'This account has been disabled. Contact your administrator.',
          'code': 'account_disabled',
        },
      );
    }

    final token = JwtService.generateToken(
      userId: user['id'] as int,
      email: user['email'] as String,
      role: user['role'] as String,
    );

    return Response.json(
      body: {
        'status': 'ok',
        'token': token,
        'user': user,
      },
    );
  } catch (e) {
    // ignore: avoid_print
    print('LOGIN ERROR: $e');

    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': 'Internal server error',
      },
    );
  }
}
