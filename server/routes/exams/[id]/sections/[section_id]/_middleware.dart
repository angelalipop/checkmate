import 'package:dart_frog/dart_frog.dart';

import '../../../../../lib/auth/auth_middleware.dart';

Handler middleware(Handler handler) {
  return authMiddleware()(handler);
}
