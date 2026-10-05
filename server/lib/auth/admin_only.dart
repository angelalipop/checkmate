import 'package:dart_frog/dart_frog.dart';

/// Must run AFTER authMiddleware (which provides the user map).
Middleware adminOnly() {
  return (handler) {
    return (context) {
      final user = context.read<Map<String, dynamic>>();

      if (user['role'] != 'admin') {
        return Response.json(
          statusCode: 403,
          body: {
            'status': 'error',
            'message': 'Administrator access required.',
          },
        );
      }

      return handler(context);
    };
  };
}
