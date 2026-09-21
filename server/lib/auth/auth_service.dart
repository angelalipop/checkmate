import 'package:postgres/postgres.dart';

import '../database.dart';
import 'password.dart';

class AuthService {
  static Future<Map<String, dynamic>?> login({
    required String email,
    required String password,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, name, email, password_hash, role
        FROM users
        WHERE LOWER(email) = LOWER(@email)
        LIMIT 1
      '''),
      parameters: {
        'email': email.trim(),
      },
    );

    if (result.isEmpty) {
      return null;
    }

    final row = result.first;

    final passwordHash = row[3] as String;

    if (!Password.verify(password, passwordHash)) {
      return null;
    }

    return {
      'id': row[0],
      'name': row[1],
      'email': row[2],
      'role': row[4],
    };
  }
}
