import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/auth_middleware.dart';

/// My Subjects is a teacher feature: the data is always the logged-in
/// teacher's own assignments, so other roles are refused.
Middleware _teacherOnly() {
  return (handler) {
    return (context) {
      final user = context.read<Map<String, dynamic>>();

      if (user['role'] != 'teacher') {
        return Response.json(
          statusCode: 403,
          body: {
            'status': 'error',
            'message': 'Teacher access required.',
          },
        );
      }

      return handler(context);
    };
  };
}

Handler middleware(Handler handler) {
  return authMiddleware()(_teacherOnly()(handler));
}
