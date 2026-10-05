import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/auth_middleware.dart';

// The one route a user with a temporary password is allowed to reach.
Handler middleware(Handler handler) {
  return authMiddleware(allowPendingPasswordChange: true)(handler);
}
