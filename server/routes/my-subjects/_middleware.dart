import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/auth_middleware.dart';

Middleware _teacherOnly() {
  return (handler) {
    return (context) {
      final user = context.read<Map<String, dynamic>>();
      final role = user['role']?.toString();
      print('MY-SUBJECTS MIDDLEWARE PATH: ${context.request.uri.path}');
  print('MY-SUBJECTS MIDDLEWARE ROLE: $role');

      // Administrators may access the exam-results email endpoint.
      final isAdminEmailRequest =
          role == 'admin' &&
          context.request.uri.path.endsWith('/email-results');

      // Teachers retain access to the existing My Subjects features.
      if (role != 'teacher' && !isAdminEmailRequest) {
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
