import 'package:dart_frog/dart_frog.dart';

import 'package:server/auth/admin_only.dart';
import 'package:server/auth/auth_middleware.dart';

/// Academic Management is administrator-only, with ONE exception: the two
/// read-only lookups the teacher Students tab needs (the program list and
/// the subject catalog search). They hold school-wide reference data only,
/// no student or exam data. Every other path and method stays admin-only.
const _teacherReadable = <String>{
  '/academic/programs',
  '/academic/subjects',
};

Handler middleware(Handler handler) {
  final adminHandler = adminOnly()(handler);

  return authMiddleware()((context) {
    final request = context.request;

    var path = request.uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    final teacherRead =
        request.method == HttpMethod.get && _teacherReadable.contains(path);

    return teacherRead ? handler(context) : adminHandler(context);
  });
}
