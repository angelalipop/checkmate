import 'package:dart_frog/dart_frog.dart';

import 'jwt_service.dart';

Middleware authMiddleware() {
  return (handler) {
    return (context) async {
      final authorization = context.request.headers['authorization'];

      if (authorization == null ||
          !authorization.startsWith('Bearer ')) {
        return Response.json(
          statusCode: 401,
          body: {
            'status': 'error',
            'message': 'Missing or invalid authorization header',
          },
        );
      }

      final token = authorization.substring(7).trim();

      try {
        final payload = JwtService.verifyToken(token);

        return handler(
          context.provide<Map<String, dynamic>>(() => payload),
        );
      } catch (e) {
        return Response.json(
          statusCode: 401,
          body: {
            'status': 'error',
            'message': 'Invalid or expired token',
          },
        );
      }
    };
  };
}
