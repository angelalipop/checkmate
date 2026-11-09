import 'package:postgres/postgres.dart';

import 'package:server/database.dart';
import 'package:server/exams/exam_validator.dart';

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
    'short_quiz',
    'long_quiz',
    'prelim',
    'midterm',
    'prefinal',
    'pre_finals',
    'final',
    'finals',
    'other',
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
    final rawType = assessmentType.trim().toLowerCase();
    final ids = classIds.toSet().toList()..sort();

    if (cleanTitle.isEmpty) {
      throw MySubjectsException('Assessment title is required.');
    }
    if (cleanTitle.length > 255) {
      throw MySubjectsException('Title must be 255 characters or fewer.');
    }
    if (!ExamValidator.isValidAssessmentType(rawType)) {
      throw MySubjectsException('Choose a valid assessment type.');
    }
    final type = ExamValidator.toDatabaseAssessmentType(rawType);
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

      for (final cid in ids) {
        await tx.execute(
          Sql.named('''
            INSERT INTO exam_class_assignments
              (exam_id, class_id, exam_version, assigned_by)
            VALUES (@exam_id, @class_id, 1, @teacher_id)
            ON CONFLICT (exam_id, class_id) DO NOTHING
          '''),
          parameters: {
            'exam_id': examId,
            'class_id': cid,
            'teacher_id': teacherId,
          },
        );
      }

      return {
        'id': examId,
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
  // POST /my-subjects/assessments/[id]/assign
  // ----------------------------------------------------------

  /// Publishes [examId] and assigns it to [classIds] (new or existing).
  ///
  /// If the assessment is already published and has student attempts, its
  /// version is bumped (`version + 1`) and the selected classes receive that
  /// new version; existing attempts stay attached to the version they were
  /// graded against.
  static Future<Map<String, dynamic>> assignAndPublish({
    required int teacherId,
    required int examId,
    required List<int> classIds,
  }) async {
    final ids = classIds.toSet().toList()..sort();
    if (ids.isEmpty) {
      throw MySubjectsException('Choose at least one section.');
    }
    if (ids.length > 30) {
      throw MySubjectsException('Too many sections selected.');
    }

    final targetSubjects = await _ownedClassSubjects(teacherId, ids);
    if (targetSubjects.toSet().length != 1) {
      throw MySubjectsException(
        'An assessment can only be given to sections of the same subject.',
      );
    }

    return Database.pool.runTx((tx) async {
      final found = await tx.execute(
        Sql.named('''
          SELECT e.id, e.status, e.version, c.teacher_id, c.subject_id,
                 (SELECT COUNT(*) FROM exam_attempts a WHERE a.exam_id = e.id),
                 e.assessment_type, e.title, e.description
          FROM exams e
          JOIN classes c ON c.id = e.class_id
          WHERE e.id = @exam_id
          FOR UPDATE OF e
        '''),
        parameters: {'exam_id': examId},
      );

      if (found.isEmpty) {
        throw MySubjectsException('Assessment not found.', statusCode: 404);
      }

      final r = found.first;
      final ownerId = r[3] as int?;
      final subjectId = r[4]! as int;
      if (ownerId != teacherId) {
        throw MySubjectsException('Assessment not found.', statusCode: 404);
      }
      if (targetSubjects.first != subjectId) {
        throw MySubjectsException(
          'Selected sections do not belong to this subject.',
        );
      }

      // Enforce minimum question validation before publishing/assigning.
      final sectionRows = await tx.execute(
        Sql.named('''
          SELECT
            es.id,
            es.name,
            es.question_type,
            es.section_order,
            COUNT(q.id)::int AS question_count
          FROM exam_sections es
          LEFT JOIN questions q ON q.section_id = es.id
          WHERE es.exam_id = @exam_id
          GROUP BY es.id, es.name, es.question_type, es.section_order
          ORDER BY es.section_order, es.id
        '''),
        parameters: {'exam_id': examId},
      );

      final sections = sectionRows
          .map(
            (sr) => <String, dynamic>{
              'id': sr[0],
              'name': sr[1],
              'question_type': sr[2],
              'section_order': sr[3],
              'question_count': sr[4],
            },
          )
          .toList();

      final validation = ExamValidator.validate(
        assessmentType: r[6]?.toString(),
        title: r[7]?.toString(),
        description: r[8]?.toString(),
        sections: sections,
      );

      if (!validation.isValid) {
        throw MySubjectsException(validation.summaryMessage);
      }

      final wasPublished = r[1] == 'published';
      final currentVersion = (r[2] as int?) ?? 1;
      final attemptCount = (r[5] as int?) ?? 0;

      // Only bump the version when re-assigning an already-used assessment.
      final nextVersion = (wasPublished && attemptCount > 0)
          ? currentVersion + 1
          : currentVersion;

      await tx.execute(
        Sql.named('''
          UPDATE exams
          SET status = 'published',
              version = @version,
              updated_at = NOW()
          WHERE id = @exam_id
        '''),
        parameters: {'exam_id': examId, 'version': nextVersion},
      );

      for (final cid in ids) {
        await tx.execute(
          Sql.named('''
            INSERT INTO exam_class_assignments
              (exam_id, class_id, exam_version, assigned_by, assigned_at)
            VALUES (@exam_id, @class_id, @version, @teacher_id, NOW())
            ON CONFLICT (exam_id, class_id) DO UPDATE
              SET exam_version = EXCLUDED.exam_version,
                  assigned_by  = EXCLUDED.assigned_by,
                  assigned_at  = NOW()
          '''),
          parameters: {
            'exam_id': examId,
            'class_id': cid,
            'version': nextVersion,
            'teacher_id': teacherId,
          },
        );
      }

      return {
        'exam_id': examId,
        'status': 'published',
        'version': nextVersion,
        'class_ids': ids,
        'validation': validation.toJson(),
      };
    });
  }

  // ----------------------------------------------------------
  // GET /my-subjects/sections/[classId]/scorebook
  // ----------------------------------------------------------

  static Future<Map<String, dynamic>> scorebook(
    int teacherId,
    int classId,
  ) async {
    await _ownedClassSubjects(teacherId, [classId]);

    final studentRows = await Database.pool.execute(
      Sql.named('''
        SELECT id, student_number, first_name, last_name
        FROM students
        WHERE class_id = @class_id
        ORDER BY LOWER(last_name), LOWER(first_name), id
      '''),
      parameters: {'class_id': classId},
    );

    final assessmentRows = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT e.id, e.title, e.assessment_type, ea.exam_version,
               (SELECT COALESCE(SUM(q.points), 0)
                  FROM questions q
                  JOIN exam_sections es ON es.id = q.section_id
                 WHERE es.exam_id = e.id) AS total_points
        FROM ea
        JOIN exams e ON e.id = ea.exam_id
        WHERE ea.class_id = @class_id
          AND e.status = 'published'
        ORDER BY e.created_at, e.id
      '''),
      parameters: {'class_id': classId},
    );

    final assessments = assessmentRows.map((r) {
      return {
        'id': r[0]! as int,
        'title': r[1],
        'assessment_type': r[2],
        'version': r[3] ?? 1,
        'total_points': _num(r[4]) ?? 0,
      };
    }).toList();

    final examIds = assessments.map((a) => a['id']! as int).toList();

    // Latest attempt per (student_number, exam_id) for this class.
    // Joining on LOWER(BTRIM(student_number)) matches how the scanner records
    // attempts in exam_attempts.student_id.
    final attempts = <String, Map<String, dynamic>>{};
    final absences = <String>{};

    if (examIds.isNotEmpty && studentRows.isNotEmpty) {
      final attemptRows = await Database.pool.execute(
        Sql.named('''
          SELECT DISTINCT ON (st.id, a.exam_id)
                 st.id AS student_id,
                 a.exam_id,
                 a.total_score,
                 a.max_score,
                 a.grading_status,
                 (SELECT COUNT(*)
                    FROM student_answers sa
                   WHERE sa.attempt_id = a.id
                     AND sa.needs_review = TRUE) AS review_count
          FROM students st
          JOIN exam_attempts a
            ON LOWER(BTRIM(a.student_id)) = LOWER(BTRIM(st.student_number))
          WHERE st.class_id = @class_id
            AND a.exam_id = ANY(@exam_ids)
          ORDER BY st.id, a.exam_id, a.scanned_at DESC, a.id DESC
        '''),
        parameters: {
          'class_id': classId,
          'exam_ids': TypedValue(Type.bigIntegerArray, examIds),
        },
      );

      for (final r in attemptRows) {
        final key = '${r[0]}|${r[1]}';
        attempts[key] = {
          'score': _num(r[2]),
          'max_score': _num(r[3]),
          'grading_status': r[4]?.toString(),
          'review_count': (r[5] as int?) ?? 0,
        };
      }

      final absenceRows = await Database.pool.execute(
        Sql.named('''
          SELECT student_id, exam_id
          FROM assessment_absences
          WHERE exam_id = ANY(@exam_ids)
            AND student_id IN (
              SELECT id FROM students WHERE class_id = @class_id
            )
        '''),
        parameters: {
          'class_id': classId,
          'exam_ids': TypedValue(Type.bigIntegerArray, examIds),
        },
      );

      for (final r in absenceRows) {
        absences.add('${r[0]}|${r[1]}');
      }
    }

    final students = studentRows.map((s) {
      final sid = s[0]! as int;
      final cells = assessments.map((a) {
        final eid = a['id']! as int;
        final key = '$sid|$eid';
        final attempt = attempts[key];

        String status;
        num? score;
        var maxScore = a['total_points'] as num?;

        if (attempt != null) {
          final gs = attempt['grading_status'];
          final rev = attempt['review_count'] as int;
          score = attempt['score'] as num?;
          maxScore = (attempt['max_score'] as num?) ?? maxScore;

          if (rev > 0 || gs == 'needs_review' || gs == 'pending_ident') {
            status = 'needs_review';
          } else {
            status = 'completed';
          }
        } else if (absences.contains(key)) {
          status = 'absent';
        } else {
          // No scan yet -> Pending. Never auto-marked as Absent.
          status = 'pending';
        }

        return {
          'exam_id': eid,
          'status': status,
          'score': score,
          'max_score': maxScore,
        };
      }).toList();

      return {
        'id': sid,
        'student_number': s[1],
        'first_name': s[2],
        'last_name': s[3],
        'cells': cells,
      };
    }).toList();

    return {
      'assessments': assessments,
      'students': students,
    };
  }

  // ----------------------------------------------------------
  // POST /my-subjects/sections/[classId]/absence
  // ----------------------------------------------------------

  static Future<void> setAbsence({
    required int teacherId,
    required int classId,
    required int examId,
    required int studentId,
    required bool absent,
  }) async {
    await _ownedClassSubjects(teacherId, [classId]);

    // Verify that the student is in this section and the exam is assigned to
    // it before writing anything.
    final check = await Database.pool.execute(
      Sql.named('''
        $_assignedCte
        SELECT
          EXISTS (
            SELECT 1 FROM students
            WHERE id = @student_id AND class_id = @class_id
          ),
          EXISTS (
            SELECT 1 FROM ea
            WHERE exam_id = @exam_id AND class_id = @class_id
          )
      '''),
      parameters: {
        'class_id': classId,
        'exam_id': examId,
        'student_id': studentId,
      },
    );

    final row = check.first;
    if (row[0] != true || row[1] != true) {
      throw MySubjectsException('Record not found.', statusCode: 404);
    }

    if (absent) {
      await Database.pool.execute(
        Sql.named('''
          INSERT INTO assessment_absences (exam_id, student_id, marked_by)
          VALUES (@exam_id, @student_id, @teacher_id)
          ON CONFLICT (exam_id, student_id) DO UPDATE
            SET marked_by = EXCLUDED.marked_by,
                marked_at = NOW()
        '''),
        parameters: {
          'exam_id': examId,
          'student_id': studentId,
          'teacher_id': teacherId,
        },
      );
    } else {
      await Database.pool.execute(
        Sql.named('''
          DELETE FROM assessment_absences
          WHERE exam_id = @exam_id AND student_id = @student_id
        '''),
        parameters: {'exam_id': examId, 'student_id': studentId},
      );
    }
  }
}
