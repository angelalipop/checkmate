import 'package:dart_frog/dart_frog.dart';
import 'package:postgres/postgres.dart';

import 'package:server/auth/jwt_service.dart';
import 'package:server/database.dart';

Response _error(int statusCode, String message, {String? code}) {
  return Response.json(
    statusCode: statusCode,
    body: {
      'status': 'error',
      'message': message,
      if (code != null) 'code': code,
    },
  );
}

/// Verifies the Bearer token AND re-checks the account in the database on
/// every request, so that:
///   * a disabled account is rejected immediately, even with a valid token;
///   * a deleted account is rejected;
///   * the role always reflects the database, not a stale token;
///   * accounts that must change their password can only reach routes that
///     opt in with [allowPendingPasswordChange].
Middleware authMiddleware({bool allowPendingPasswordChange = false}) {
  return (handler) {
    return (context) async {
      final authorization = context.request.headers['authorization'];

      if (authorization == null || !authorization.startsWith('Bearer ')) {
        return _error(401, 'Missing or invalid authorization header');
      }

      final token = authorization.substring(7).trim();

      final Map<String, dynamic> payload;

      try {
        payload = JwtService.verifyToken(token);
      } catch (_) {
        return _error(401, 'Invalid or expired token');
      }

      final userId = int.tryParse(payload['userId']?.toString() ?? '');

      if (userId == null) {
        return _error(401, 'Invalid or expired token');
      }

      final Result result;

      try {
        result = await Database.pool.execute(
          Sql.named('''
            SELECT name, email, role, username, is_active,
                   must_change_password
            FROM users
            WHERE id = @id
          '''),
          parameters: {'id': userId},
        );
      } catch (e) {
        // ignore: avoid_print
        print('AUTH LOOKUP ERROR: $e');
        return _error(500, 'Unable to verify account');
      }

      if (result.isEmpty) {
        return _error(401, 'This account no longer exists.');
      }

      final row = result.first;
      final isActive = row[4]! as bool;
      final mustChange = row[5]! as bool;

      if (!isActive) {
        return _error(
          403,
          'This account has been disabled. Contact your administrator.',
          code: 'account_disabled',
        );
      }

      if (mustChange && !allowPendingPasswordChange) {
        return _error(
          403,
          'You must change your temporary password before continuing.',
          code: 'password_change_required',
        );
      }

      final user = <String, dynamic>{
        ...payload,
        'userId': userId,
        'name': row[0],
        'email': row[1],
        'role': row[2],
        'username': row[3],
        'mustChangePassword': mustChange,
      };

      return handler(context.provide<Map<String, dynamic>>(() => user));
    };
  };
}
