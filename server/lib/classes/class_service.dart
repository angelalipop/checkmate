import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class ClassService {
  /// "BSIT 1-A" -> 1, "BSIT-3A" -> 3. Null when no year digit (1-6) is found.
  static int? inferYearLevel(String section) {
    final match = RegExp(r'[1-6]').firstMatch(section);
    return match == null ? null : int.parse(match.group(0)!);
  }

  /// When [teacherId] is given, only that teacher's sections are returned.
  static Future<List<Map<String, dynamic>>> getAll({int? teacherId}) async {
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
          c.created_at,
          c.year_level
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN users u ON u.id = c.teacher_id
        ${teacherId == null ? '' : 'WHERE c.teacher_id = @teacher_id'}
        ORDER BY c.id
      '''),
      parameters: teacherId == null ? null : {'teacher_id': teacherId},
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
        'year_level': row[10],
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
          semester,
          year_level
        )
        VALUES (
          @subject_id,
          @teacher_id,
          @section,
          @school_year,
          @semester,
          NULLIF(@year_level, 0)
        )
        RETURNING
          id,
          subject_id,
          teacher_id,
          section,
          school_year,
          semester,
          created_at,
          year_level
      '''),
      parameters: {
        'subject_id': subjectId,
        'teacher_id': teacherId,
        'section': section.trim(),
        'school_year': schoolYear?.trim(),
        'semester': semester?.trim(),
        'year_level': inferYearLevel(section) ?? 0,
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
      'year_level': row[7],
    };
  }
}
