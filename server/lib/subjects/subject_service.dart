import 'package:postgres/postgres.dart';

import '../database.dart';

class SubjectService {
  static Future<List<Map<String, dynamic>>> getAll() async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, name, code, created_at
        FROM subjects
        ORDER BY name
      '''),
    );

    return result
        .map(
          (row) => {
            'id': row[0],
            'name': row[1],
            'code': row[2],
            'created_at': row[3].toString(),
          },
        )
        .toList();
  }

  static Future<Map<String, dynamic>> create({
    required String name,
    String? code,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO subjects (name, code)
        VALUES (@name, @code)
        RETURNING id, name, code, created_at
      '''),
      parameters: {
        'name': name.trim(),
        'code': code?.trim(),
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'name': row[1],
      'code': row[2],
      'created_at': row[3].toString(),
    };
  }
}
