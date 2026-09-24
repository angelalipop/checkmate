import 'package:dart_frog/dart_frog.dart';

import '../../lib/users/user_service.dart';

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

    final name = body['name']?.toString().trim();
    final email = body['email']?.toString().trim();
    final password = body['password']?.toString();

    if (name == null || name.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Name is required',
        },
      );
    }

    if (email == null || email.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Email is required',
        },
      );
    }

    if (password == null || password.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Password is required',
        },
      );
    }

    if (password.length < 6) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'Password must be at least 6 characters',
        },
      );
    }

    final teacher = await UserService.createTeacher(
      name: name,
      email: email,
      password: password,
    );

    return Response.json(
      statusCode: 201,
      body: {
        'status': 'ok',
        'user': teacher,
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