import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/admin_only.dart';
import 'package:server/auth/auth_middleware.dart';

Handler middleware(Handler handler) {
  return authMiddleware()(adminOnly()(handler));
}
