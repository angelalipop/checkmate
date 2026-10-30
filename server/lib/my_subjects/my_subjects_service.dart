import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

/// An error whose [message] is safe to show to the teacher.
class MySubjectsException implements Exception {
  MySubjectsException(this.message, {this.statusCode = 400});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

/// Everything here is scoped by [teacherId], which always comes from the
/// verified login token (never from the request). A class, student or exam
/// that does not belong to that teacher is reported as "not found".
class MySubjectsService {
  static const assessmentTypes = <String>{
    'quiz',
    'long_quiz',
    'prelim',
    'midterm',
    'prefinal',
    'final',
  };

  /// Which classes an assessment is given to, with the version each got.
  /// Exams created before the assignment table existed (or by older code
  /// that only sets exams.class_id) still count for their own class.
  static const _assignedCte = '''
    WITH ea AS (
      SELECT exam_id, class_id, exam_version
      FROM exam_class_assignments
      UNION
      SELECT e.id, e.class_id, e.version
      FROM exams e
      WHERE NOT EXISTS (
        SELECT 1 FROM exam_class_assignments x
        WHERE x.exam_id = e.id AND x.class_id = e.class_id
      )
    )
  ''';

  static int? _semesterNo(Object? raw) {
    final m = RegExp(r'^\d').firstMatch(raw?.toString().trim() ?? '');
    return m == null ? null : int.parse(m.group(0)!);
  }

  static num? _num(Object? v) => v == null ? null : num.tryParse('$v');

  // ----------------------------------------------------------
  // GET /my-subjects
  // ----------------------------------------------------------

  static Future<List<Map<String, dynamic>>> listSubjects(
    int teacherId,
  ) async {
    final classes = await Database.pool.execute(
      Sql.named('''
        SELECT c.id, c.section, c.school_year, c.semester, c.year_level,
               s.id, s.code, s.name,
               pr.program_id, pr.program_code, pr.program_level
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN LATERAL (
          SELECT sec.program_id, p.code AS program_code,
                 p.level AS program_level
          FROM sections sec
          JOIN academic_programs p ON p.id = sec.program_id
          WHERE LOWER(sec.name) = LOWER(c.section)
            AND (c.school_year IS NULL OR sec.school_year = c.school_year)
          ORDER BY (
                     c.semester IS NOT DISTINCT FROM CASE sec.semester
                       WHEN 1 THEN '1st Semester'
                       WHEN 2 THEN '2nd Semester'
                     END
                   ) DESC,
                   sec.school_year DESC, sec.semester DESC
          LIMIT 1
        ) pr ON TRUE
        WHERE c.teacher_id = @teacher_id
        ORDER BY LOWER(s.name), c.year_level NULLS LAST, LOWER(c.section)
      '''),
      parameters: {'teacher_id': teacherId},
    );

    final students = await Database.pool.execute(
      Sql.named('''
        SELECT st.class_id, LOWER(BTRIM(st.student_number))
        FROM students st
        JOIN classes c ON c.id = st.class_id
        WHERE c.teacher_id = @teacher_id
      '''),
      parameters: {'teacher_id': teacherId},
    );

    final byClass = <int, Set<String>>{};
    for (final r in students) {
      byClass
          .putIfAbsent(r[0]! as int, () => <String>{})
          .add((r[1] ?? '').toString());
    }

    // One card per Subject + program + year + semester + school year, so the
    // same subject taught in different academic contexts is never merged.
    final cards = <String, Map<String, dynamic>>{};
    final cardStudents = <String, Set<String>>{};

    for (final r in classes) {
      final classId = r[0]! as int;
      final semesterText = r[3]?.toString();
      final key = '${r[5]}|${r[8]}|${r[4]}|${_semesterNo(semesterText)}|'
          '${r[2]}';

      final card = cards.putIfAbsent(
        key,
        () => {
          'key': key,
          'subject_id': r[5],
          'code': r[6],
          'name': r[7],
          'department': r[10], // 'college' | 'shs' | null
          'program_id': r[8],
          'program_code': r[9],
          'year_level': r[4],
          'semester': _semesterNo(semesterText),
          'semester_label': semesterText,
          'school_year': r[2],
          'sections': <Map<String, dynamic>>[],
        },
      );

      final ids = byClass[classId] ?? <String>{};
      (card['sections'] as List<Map<String, dynamic>>).add({
        'class_id': classId,
        'name': r[1],
        'students': ids.length,
      });
      cardStudents.putIfAbsent(key, () => <String>{}).addAll(ids);
    }

    return cards.entries.map((e) {
      return {
        ...e.value,
        'total_students': cardStudents[e.key]?.length ?? 0,
      };
    }).toList();
  }

  // ----------------------------------------------------------
  // Ownership
  // ----------------------------------------------------------

  /// Returns the subject ids of [classIds] when ALL of them belong to the
  /// teacher; otherwise throws a 404 (the same answer for "not yours" and
  /// "does not exist", so ids cannot be probed).
  static Future<List<int>> _ownedClassSubjects(
    int teacherId,
    List<int> classIds,
  ) async {
    final rows = await Database.pool.execute(
      Sql.named('''
        SELECT id, subject_id FROM classes
        WHERE teacher_id = @teacher_id AND id = ANY(@ids)
      '''),
      parameters: {
        'teacher_id': teacherId,
        'ids': TypedValue(Type.bigIntegerArray, classIds),
      },
    );

    if (rows.length != classIds.toSet().length) {
      throw MySubjectsException('Section not found.', statusCode: 404);
    }

    return rows.map((r) => r[1]! as int).toList();
  }

  // ----------------------------------------------------------
  // GET /my-subjects/assessments?class_ids=1,2
  // ----------------------------------------------------------

  static Future<List<Map<String, dynamic>>> listAssessments(
    int teacherId,
    List<int> classIds,
  ) async {
    if (classIds.isEmpty) return [];
    await _ownedClassSubjects(teacherId, classIds);

    final rows = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT e.id, e.title, e.assessment_type, e.status, e.created_at,
               (SELECT COUNT(*)
                  FROM questions q
                  JOIN exam_sections es ON es.id = q.section_id
                 WHERE es.exam_id = e.id) AS question_count,
               MAX(ea.exam_version) AS version,
               (SELECT string_agg(c2.section, '|' ORDER BY c2.section)
                  FROM ea ea2
                  JOIN classes c2 ON c2.id = ea2.class_id
                 WHERE ea2.exam_id = e.id
                   AND c2.teacher_id = @teacher_id) AS sections
        FROM exams e
        JOIN ea ON ea.exam_id = e.id
        WHERE ea.class_id = ANY(@ids)
        GROUP BY e.id
        ORDER BY e.created_at DESC, e.id DESC
      '''),
      parameters: {
        'teacher_id': teacherId,
        'ids': TypedValue(Type.bigIntegerArray, classIds),
      },
    );

    return rows.map((r) {
      final sections = (r[7]?.toString() ?? '')
          .split('|')
          .where((s) => s.isNotEmpty)
          .toList();
      return {
        'id': r[0],
        'title': r[1],
        'assessment_type': r[2],
        'status': r[3],
        'created_at': r[4].toString(),
        'question_count': r[5],
        'version': r[6],
        'sections': sections,
      };
    }).toList();
  }

  // ----------------------------------------------------------
  // POST /my-subjects/assessments
  // ----------------------------------------------------------

  static Future<Map<String, dynamic>> createAssessment({
    required int teacherId,
    required List<int> classIds,
    required String title,
    required String assessmentType,
    String? description,
    String? instructions,
  }) async {
    final cleanTitle = title.trim();
    final type = assessmentType.trim().toLowerCase();
    final ids = classIds.toSet().toList()..sort();

    if (cleanTitle.isEmpty) {
      throw MySubjectsException('Assessment title is required.');
    }
    if (cleanTitle.length > 255) {
      throw MySubjectsException('Title must be 255 characters or fewer.');
    }
    if (!assessmentTypes.contains(type)) {
      throw MySubjectsException('Choose a valid assessment type.');
    }
    if (ids.isEmpty) {
      throw MySubjectsException('Choose at least one section.');
    }
    if (ids.length > 30) {
      throw MySubjectsException('Too many sections selected.');
    }

    final subjects = await _ownedClassSubjects(teacherId, ids);
    if (subjects.toSet().length != 1) {
      throw MySubjectsException(
        'An assessment can only be given to sections of the same subject.',
      );
    }

    String? clean(String? v) =>
        (v == null || v.trim().isEmpty) ? null : v.trim();

    return Database.pool.runTx((tx) async {
      final created = await tx.execute(
        Sql.named('''
          INSERT INTO exams (
            class_id, title, description, instructions,
            status, assessment_type, version
          )
          VALUES (
            @class_id, @title, @description, @instructions,
            'draft', @type, 1
          )
          RETURNING id, class_id, title, status, assessment_type, version
        '''),
        parameters: {
          'class_id': ids.first,
          'title': cleanTitle,
          'description': clean(description),
          'instructions': clean(instructions),
          'type': type,
        },
      );

      final row = created.first;
      final examId = row[0]! as int;

      for (final classId in ids) {
        await tx.execute(
          Sql.named('''
            INSERT INTO exam_class_assignments
              (exam_id, class_id, exam_version, assigned_by)
            VALUES (@exam_id, @class_id, 1, @user_id)
            ON CONFLICT (exam_id, class_id) DO NOTHING
          '''),
          parameters: {
            'exam_id': examId,
            'class_id': classId,
            'user_id': teacherId,
          },
        );
      }

      return {
        'id': row[0],
        'class_id': row[1],
        'title': row[2],
        'status': row[3],
        'assessment_type': row[4],
        'version': row[5],
        'class_ids': ids,
      };
    });
  }

  // ----------------------------------------------------------
  // GET /my-subjects/classes/{id}/scorebook
  // ----------------------------------------------------------

  static Future<Map<String, dynamic>> scorebook(
    int teacherId,
    int classId,
  ) async {
    final cls = await Database.pool.execute(
      Sql.named('''
        SELECT c.id, c.section, c.school_year, c.semester, c.year_level,
               s.id, s.code, s.name,
               pr.program_id, pr.program_code, pr.program_level
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN LATERAL (
          SELECT sec.program_id, p.code AS program_code,
                 p.level AS program_level
          FROM sections sec
          JOIN academic_programs p ON p.id = sec.program_id
          WHERE LOWER(sec.name) = LOWER(c.section)
            AND (c.school_year IS NULL OR sec.school_year = c.school_year)
          ORDER BY (
                     c.semester IS NOT DISTINCT FROM CASE sec.semester
                       WHEN 1 THEN '1st Semester'
                       WHEN 2 THEN '2nd Semester'
                     END
                   ) DESC,
                   sec.school_year DESC, sec.semester DESC
          LIMIT 1
        ) pr ON TRUE
        WHERE c.id = @class_id AND c.teacher_id = @teacher_id
      '''),
      parameters: {'class_id': classId, 'teacher_id': teacherId},
    );

    if (cls.isEmpty) {
      throw MySubjectsException('Section not found.', statusCode: 404);
    }
    final c = cls.first;

    final studentRows = await Database.pool.execute(
      Sql.named('''
        SELECT id, student_number, first_name, last_name
        FROM students
        WHERE class_id = @class_id
        ORDER BY LOWER(last_name), LOWER(first_name), id
      '''),
      parameters: {'class_id': classId},
    );

    final examRows = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT e.id, e.title, e.assessment_type, e.status, ea.exam_version
        FROM ea
        JOIN exams e ON e.id = ea.exam_id
        WHERE ea.class_id = @class_id
        ORDER BY e.created_at ASC, e.id ASC
      '''),
      parameters: {'class_id': classId},
    );

    // Latest attempt per (exam, student). Only students of THIS class are
    // joined, so another section's scores can never appear here.
    final attemptRows = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT DISTINCT ON (a.exam_id, a.student_id)
               a.exam_id, a.student_id, a.status, a.score, a.max_score,
               EXISTS (
                 SELECT 1 FROM student_answers sa
                 WHERE sa.attempt_id = a.id
                   AND sa.verification_status = 'needs_review'
               ) AS has_review
        FROM exam_attempts a
        JOIN students st ON st.id = a.student_id
        WHERE st.class_id = @class_id
          AND a.exam_id IN (SELECT exam_id FROM ea WHERE class_id = @class_id)
        ORDER BY a.exam_id, a.student_id, a.created_at DESC, a.id DESC
      '''),
      parameters: {'class_id': classId},
    );

    final absenceRows = await Database.pool.execute(
      Sql.named('''
        SELECT ab.exam_id, ab.student_id
        FROM assessment_absences ab
        JOIN students st ON st.id = ab.student_id
        WHERE st.class_id = @class_id
      '''),
      parameters: {'class_id': classId},
    );

    final attempts = <String, ResultRow>{
      for (final r in attemptRows) '${r[0]}|${r[1]}': r,
    };
    final absent = <String>{
      for (final r in absenceRows) '${r[0]}|${r[1]}',
    };

    final assessments = examRows
        .map((r) => {
              'id': r[0],
              'title': r[1],
              'assessment_type': r[2],
              'status': r[3],
              'version': r[4],
            })
        .toList();

    final students = studentRows.map((s) {
      final cells = <Map<String, dynamic>>[];

      for (final exam in examRows) {
        final key = '${exam[0]}|${s[0]}';
        final a = attempts[key];

        var status = 'pending';
        num? score;
        num? maxScore;

        if (a != null && a[2] == 'completed') {
          status = 'completed';
          score = _num(a[3]);
          maxScore = _num(a[4]);
        } else if (a != null && (a[2] == 'pending_verification' || a[5] == true)) {
          status = 'needs_review';
        } else if (absent.contains(key)) {
          status = 'absent';
        }
        // Anything else (no attempt, or a scan still processing) stays
        // Pending: never a zero, never absent unless the teacher said so.

        cells.add({
          'exam_id': exam[0],
          'status': status,
          'score': score,
          'max_score': maxScore,
        });
      }

      return {
        'id': s[0],
        'student_number': s[1],
        'first_name': s[2],
        'last_name': s[3],
        'cells': cells,
      };
    }).toList();

    return {
      'class': {
        'id': c[0],
        'section': c[1],
        'school_year': c[2],
        'semester_label': c[3],
        'semester': _semesterNo(c[3]),
        'year_level': c[4],
        'subject_id': c[5],
        'subject_code': c[6],
        'subject_name': c[7],
        'program_id': c[8],
        'program_code': c[9],
        'department': c[10],
      },
      'assessments': assessments,
      'students': students,
    };
  }

  // ----------------------------------------------------------
  // PUT /my-subjects/classes/{id}/absences
  // ----------------------------------------------------------

  static Future<void> setAbsence({
    required int teacherId,
    required int classId,
    required int examId,
    required int studentId,
    required bool absent,
  }) async {
    await _ownedClassSubjects(teacherId, [classId]);

    final student = await Database.pool.execute(
      Sql.named('SELECT 1 FROM students WHERE id = @s AND class_id = @c'),
      parameters: {'s': studentId, 'c': classId},
    );
    if (student.isEmpty) {
      throw MySubjectsException('Student not found.', statusCode: 404);
    }

    final assigned = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT 1 FROM ea WHERE exam_id = @e AND class_id = @c
      '''),
      parameters: {'e': examId, 'c': classId},
    );
    if (assigned.isEmpty) {
      throw MySubjectsException('Assessment not found.', statusCode: 404);
    }

    if (!absent) {
      await Database.pool.execute(
        Sql.named(
          'DELETE FROM assessment_absences '
          'WHERE exam_id = @e AND student_id = @s',
        ),
        parameters: {'e': examId, 's': studentId},
      );
      return;
    }

    final done = await Database.pool.execute(
      Sql.named('''
        SELECT 1 FROM exam_attempts
        WHERE exam_id = @e AND student_id = @s AND status = 'completed'
      '''),
      parameters: {'e': examId, 's': studentId},
    );
    if (done.isNotEmpty) {
      throw MySubjectsException(
        'This student already has a finalized result, so they cannot be '
        'marked absent.',
        statusCode: 409,
      );
    }

    await Database.pool.execute(
      Sql.named('''
        INSERT INTO assessment_absences (exam_id, student_id, marked_by)
        VALUES (@e, @s, @u)
        ON CONFLICT (exam_id, student_id) DO NOTHING
      '''),
      parameters: {'e': examId, 's': studentId, 'u': teacherId},
    );
  }
}
