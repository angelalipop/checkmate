import 'package:postgres/postgres.dart';

import '../database.dart';

class ClassService {
  static Future<List<Map<String, dynamic>>> getAll() async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          c.id,
          c.section,
          c.school_year,
          c.semester,
          c.subject_id,
          s.name AS subject_name,
          s.code AS subject_code,
          c.teacher_id,
          u.name AS teacher_name,
          c.created_at
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
        JOIN users u ON u.id = c.teacher_id
        ORDER BY c.id
      '''),
    );

    return result.map((row) {
      return {
        'id': row[0],
        'section': row[1],
        'school_year': row[2],
        'semester': row[3],
        'subject': {
          'id': row[4],
          'name': row[5],
          'code': row[6],
        },
        'teacher': {
          'id': row[7],
          'name': row[8],
        },
        'created_at': row[9].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int subjectId,
    required int teacherId,
    required String section,
    String? schoolYear,
    String? semester,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO classes (
          subject_id,
          teacher_id,
          section,
          school_year,
          semester
        )
        VALUES (
          @subject_id,
          @teacher_id,
          @section,
          @school_year,
          @semester
        )
        RETURNING
          id,
          subject_id,
          teacher_id,
          section,
          school_year,
          semester,
          created_at
      '''),
      parameters: {
        'subject_id': subjectId,
        'teacher_id': teacherId,
        'section': section.trim(),
        'school_year': schoolYear?.trim(),
        'semester': semester?.trim(),
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'subject_id': row[1],
      'teacher_id': row[2],
      'section': row[3],
      'school_year': row[4],
      'semester': row[5],
      'created_at': row[6].toString(),
    };
  }
}
