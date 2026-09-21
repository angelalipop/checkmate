import 'package:dart_frog/dart_frog.dart';

import '../../../lib/auth/auth_service.dart';

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

    final email = body['email']?.toString();
    final password = body['password']?.toString();

    if (email == null ||
        email.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Email and password are required',
        },
      );
    }

    final user = await AuthService.login(
      email: email,
      password: password,
    );

    if (user == null) {
      return Response.json(
        statusCode: 401,
        body: {
          'status': 'error',
          'message': 'Invalid email or password',
        },
      );
    }

    return Response.json(
      body: {
        'status': 'ok',
        'user': user,
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

