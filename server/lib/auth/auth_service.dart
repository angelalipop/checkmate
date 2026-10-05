import 'package:postgres/postgres.dart';

import 'package:server/auth/password.dart';
import 'package:server/database.dart';

class AuthException implements Exception {
  AuthException(this.message, {this.statusCode = 400});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

class AuthService {
  /// [identifier] may be an email address or a username.
  /// Returns null for unknown user OR wrong password (same result, so the
  /// response never reveals which accounts exist).
  static Future<Map<String, dynamic>?> login({
    required String identifier,
    required String password,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, name, email, password_hash, role,
               username, is_active, must_change_password
        FROM users
        WHERE LOWER(email) = LOWER(@identifier)
           OR LOWER(username) = LOWER(@identifier)
        LIMIT 1
      '''),
      parameters: {
        'identifier': identifier.trim(),
      },
    );

    if (result.isEmpty) {
      return null;
    }

    final row = result.first;

    final passwordHash = row[3]! as String;

    if (!Password.verify(password, passwordHash)) {
      return null;
    }

    return {
      'id': row[0],
      'name': row[1],
      'email': row[2],
      'role': row[4],
      'username': row[5],
      'is_active': row[6],
      'must_change_password': row[7],
    };
  }

  static Future<void> changePassword({
    required int userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    if (newPassword.length < 8) {
      throw AuthException('New password must be at least 8 characters.');
    }

    if (newPassword == currentPassword) {
      throw AuthException(
        'New password must be different from the temporary password.',
      );
    }

    final result = await Database.pool.execute(
      Sql.named('SELECT password_hash FROM users WHERE id = @id'),
      parameters: {'id': userId},
    );

    if (result.isEmpty) {
      throw AuthException('Account not found.', statusCode: 404);
    }

    final hash = result.first[0]! as String;

    if (!Password.verify(currentPassword, hash)) {
      throw AuthException('Current password is incorrect.', statusCode: 401);
    }

    await Database.pool.execute(
      Sql.named('''
        UPDATE users
        SET password_hash = @hash,
            must_change_password = FALSE,
            updated_at = NOW()
        WHERE id = @id
      '''),
      parameters: {
        'hash': Password.hash(newPassword),
        'id': userId,
      },
    );
  }
}
