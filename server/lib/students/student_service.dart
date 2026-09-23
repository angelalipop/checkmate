import 'package:postgres/postgres.dart';

import '../database.dart';

class StudentService {
  static Future<List<Map<String, dynamic>>> getAll({
    int? classId,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          s.id,
          s.class_id,
          s.student_number,
          s.first_name,
          s.last_name,
          s.email,
          s.created_at,
          c.section,
          sub.name AS subject_name,
          sub.code AS subject_code
        FROM students s
        JOIN classes c ON c.id = s.class_id
        JOIN subjects sub ON sub.id = c.subject_id
        WHERE (@class_id::bigint IS NULL OR s.class_id = @class_id)
        ORDER BY s.id
      '''),
      parameters: {
        'class_id': classId,
      },
    );

    return result.map((row) {
      return {
        'id': row[0],
        'class_id': row[1],
        'student_number': row[2],
        'first_name': row[3],
        'last_name': row[4],
        'email': row[5],
        'class': {
          'id': row[1],
          'section': row[7],
          'subject': {
            'name': row[8],
            'code': row[9],
          },
        },
        'created_at': row[6].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int classId,
    required String studentNumber,
    required String firstName,
    required String lastName,
    String? email,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO students (
          class_id,
          student_number,
          first_name,
          last_name,
          email
        )
        VALUES (
          @class_id,
          @student_number,
          @first_name,
          @last_name,
          @email
        )
        RETURNING
          id,
          class_id,
          student_number,
          first_name,
          last_name,
          email,
          created_at
      '''),
      parameters: {
        'class_id': classId,
        'student_number': studentNumber.trim(),
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'email': email?.trim(),
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'class_id': row[1],
      'student_number': row[2],
      'first_name': row[3],
      'last_name': row[4],
      'email': row[5],
      'created_at': row[6].toString(),
    };
  }
}
