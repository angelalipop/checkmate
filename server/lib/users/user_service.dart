import 'package:postgres/postgres.dart';

import '../database.dart';
import '../auth/password.dart';

class UserService {
  static Future<Map<String, dynamic>> createTeacher({
    required String name,
    required String email,
    required String password,
  }) async {
    final passwordHash = Password.hash(password);

    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO users (
          name,
          email,
          password_hash,
          role
        )
        VALUES (
          @name,
          @email,
          @password_hash,
          'teacher'
        )
        RETURNING id, name, email, role, created_at
      '''),
      parameters: {
        'name': name.trim(),
        'email': email.trim().toLowerCase(),
        'password_hash': passwordHash,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'name': row[1],
      'email': row[2],
      'role': row[3],
      'created_at': row[4].toString(),
    };
  }
}