import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/admin_only.dart';
import 'package:server/auth/auth_middleware.dart';

// Applies to /teachers and every nested route. authMiddleware runs first
// (verifies token + account is active), then adminOnly.
Handler middleware(Handler handler) {
  return authMiddleware()(adminOnly()(handler));
}
