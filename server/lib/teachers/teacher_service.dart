import 'package:postgres/postgres.dart';

import '../database.dart';

class TeacherService {
  static Future<List<Map<String, dynamic>>> getAll() async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, name, email
        FROM users
        WHERE LOWER(role) = 'teacher'
        ORDER BY name
      '''),
    );

    return result
        .map(
          (row) => {
            'id': row[0],
            'name': row[1],
            'email': row[2],
          },
        )
        .toList();
  }
}