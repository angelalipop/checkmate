import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class ClassService {
  /// "BSIT 1-A" -> 1, "BSIT-3A" -> 3. Null when no year digit (1-6) is found.
  static int? inferYearLevel(String section) {
    final match = RegExp('[1-6]').firstMatch(section);
    return match == null ? null : int.parse(match.group(0)!);
  }

  /// "BSIT:3:1,BSIT:3:2" -> [{program: BSIT, year_level: 3, term: 1}, ...]
  static List<Map<String, dynamic>> _parsePlacements(Object? raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return [];
    final out = <Map<String, dynamic>>[];
    for (final part in text.split(',')) {
      final bits = part.split(':');
      if (bits.length != 3) continue;
      final year = int.tryParse(bits[1]);
      final term = int.tryParse(bits[2]);
      if (year == null || term == null) continue;
      out.add({'program': bits[0], 'year_level': year, 'term': term});
    }
    return out;
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
          COALESCE(a.name, s.name) AS subject_name,
          COALESCE(a.code, s.code) AS subject_code,
          c.teacher_id,
          u.name AS teacher_name,
          c.created_at,
          c.year_level,
          COALESCE(s.academic_subject_id, a.id) AS academic_subject_id,
          (
            SELECT COUNT(DISTINCT LOWER(BTRIM(st.student_number)))
            FROM students st
            WHERE st.class_id = c.id
          ) AS student_count,
          (
            SELECT string_agg(
                     DISTINCT p.code || ':' || cs.year_level::text
                              || ':' || cs.term::text,
                     ','
                   )
            FROM curriculum_subjects cs
            JOIN curricula cu
              ON cu.id = cs.curriculum_id AND cu.is_deleted = FALSE
            JOIN academic_programs p
              ON p.id = cu.program_id AND p.is_deleted = FALSE
            WHERE cs.subject_id = COALESCE(s.academic_subject_id, a.id)
              AND cs.is_deleted = FALSE
          ) AS placements
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN LATERAL (
          SELECT ac.id, ac.code, ac.name
          FROM academic_subjects ac
          WHERE ac.is_deleted = FALSE
            AND (
              ac.id = s.academic_subject_id
              OR (
                s.academic_subject_id IS NULL
                AND (
                  (s.code IS NOT NULL AND ac.code IS NOT NULL AND LOWER(ac.code) = LOWER(s.code))
                  OR LOWER(ac.name) = LOWER(s.name)
                )
              )
            )
          ORDER BY (ac.id = s.academic_subject_id) DESC, ac.id
          LIMIT 1
        ) a ON TRUE
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
          // Link to the Academic Management subject (resolved from 003_academic_module).
          'academic_subject_id': row[11],
          'placements': _parsePlacements(row[13]),
        },
        'teacher': {
          'id': row[7],
          'name': row[8],
        },
        'created_at': row[9].toString(),
        'year_level': row[10],
        // Number of distinct students enrolled in this class.
        'student_count': row[12],
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
