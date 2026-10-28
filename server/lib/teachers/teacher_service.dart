import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:server/auth/password.dart';
import 'package:server/database.dart';
import 'package:server/teachers/teacher_exception.dart';
import 'package:server/teachers/teacher_identity.dart';

export 'package:server/teachers/teacher_exception.dart';

/// One Subject + Section the teacher teaches.
class AssignmentInput {
  AssignmentInput({
    required this.section,
    this.subjectId,
    this.academicSubjectId,
    this.schoolYear = '',
    this.semester = '',
  });

  /// The subject row classes use (subjects.id). May be null when the admin
  /// picked a subject straight from Academic Management that has no such row
  /// yet; [academicSubjectId] is then resolved to one on save.
  final int? subjectId;

  /// academic_subjects.id, the Academic Management subject.
  final int? academicSubjectId;
  final String section;
  final String schoolYear;
  final String semester;
}

class TeacherService {
  /// Parses the "assignments" array sent by the app. Returns null when the
  /// key was not sent at all (so "leave assignments alone" and "remove all
  /// of them" stay different things).
  static List<AssignmentInput>? parseAssignments(dynamic raw) {
    if (raw == null) return null;

    if (raw is! List) {
      throw TeacherException('assignments must be a list.');
    }

    final out = <AssignmentInput>[];

    for (final item in raw) {
      if (item is! Map) {
        throw TeacherException('Invalid assignment entry.');
      }

      final subjectId = int.tryParse(item['subject_id']?.toString() ?? '');
      final academicSubjectId =
          int.tryParse(item['academic_subject_id']?.toString() ?? '');
      final section = item['section']?.toString().trim() ?? '';

      if (subjectId == null && academicSubjectId == null) {
        throw TeacherException('Each assignment needs a subject.');
      }

      if (section.isEmpty) {
        throw TeacherException('Each assignment needs a section.');
      }

      out.add(
        AssignmentInput(
          subjectId: subjectId,
          academicSubjectId: academicSubjectId,
          section: section,
          schoolYear: item['school_year']?.toString().trim() ?? '',
          semester: item['semester']?.toString().trim() ?? '',
        ),
      );
    }

    return out;
  }

  static Future<void> _assertUnique(
    Session session, {
    required String teacherIdNo,
    required String email,
    int excludeId = -1,
  }) async {
    final result = await session.execute(
      Sql.named('''
        SELECT
          (LOWER(teacher_id_no) = LOWER(@teacher_id_no)) AS id_match,
          (LOWER(email) = LOWER(@email)
           OR LOWER(username) = LOWER(@email)) AS email_match
        FROM users
        WHERE (LOWER(teacher_id_no) = LOWER(@teacher_id_no)
               OR LOWER(email) = LOWER(@email)
               OR LOWER(username) = LOWER(@email))
          AND id <> @exclude_id
      '''),
      parameters: {
        'teacher_id_no': teacherIdNo,
        'email': email,
        'exclude_id': excludeId,
      },
    );

    for (final row in result) {
      if (row[0] == true) {
        throw TeacherException(
          'This Teacher ID No. already belongs to another teacher.',
          statusCode: 409,
        );
      }
    }

    for (final row in result) {
      if (row[1] == true) {
        throw TeacherException(
          'The generated email $email is already in use.',
          statusCode: 409,
        );
      }
    }
  }

  static Future<void> _requireTeacher(Session session, int id) async {
    final result = await session.execute(
      Sql.named(
        "SELECT 1 FROM users WHERE id = @id AND role = 'teacher' "
        'FOR UPDATE',
      ),
      parameters: {'id': id},
    );

    if (result.isEmpty) {
      throw TeacherException('Teacher not found.', statusCode: 404);
    }
  }

  /// The subjects row (what classes point at) for an Academic Management
  /// subject. An existing row is reused (already linked, else the same code,
  /// else the same name); a row is created only when none exists, so no
  /// duplicate subject is made. With [create] false nothing is written.
  static Future<int?> _legacySubjectFor(
    Session session,
    int academicSubjectId, {
    required bool create,
  }) async {
    final acad = await session.execute(
      Sql.named('''
        SELECT code, name FROM academic_subjects
        WHERE id = @id AND is_deleted = FALSE
      '''),
      parameters: {'id': academicSubjectId},
    );

    if (acad.isEmpty) {
      throw TeacherException('The selected subject does not exist.');
    }

    final code = acad.first[0] as String?;
    final name = acad.first[1]! as String;

    final found = await session.execute(
      Sql.named('''
        SELECT id FROM subjects
        WHERE academic_subject_id = @a
           OR (
             academic_subject_id IS NULL
             AND (
               (@code::text IS NOT NULL AND LOWER(code) = LOWER(@code::text))
               OR LOWER(name) = LOWER(@name)
             )
           )
        ORDER BY (academic_subject_id IS NOT NULL) DESC, id
        LIMIT 1
      '''),
      parameters: {'a': academicSubjectId, 'code': code, 'name': name},
    );

    if (found.isNotEmpty) {
      final id = found.first[0]! as int;
      if (create) {
        await session.execute(
          Sql.named('''
            UPDATE subjects SET academic_subject_id = @a
            WHERE id = @id AND academic_subject_id IS NULL
          '''),
          parameters: {'a': academicSubjectId, 'id': id},
        );
      }
      return id;
    }

    if (!create) return null;

    final inserted = await session.execute(
      Sql.named('''
        INSERT INTO subjects (name, code, academic_subject_id)
        VALUES (@name, @code, @a)
        RETURNING id
      '''),
      parameters: {
        'name': name.length > 150 ? name.substring(0, 150) : name,
        'code': code,
        'a': academicSubjectId,
      },
    );

    return inserted.first[0]! as int;
  }

  /// Subjects of a program's published curriculum with the year level and
  /// term each is taught in, from Academic Management. An elective slot is
  /// replaced by the elective finalized for each school year (the row then
  /// has that 'school_year'); a slot with none yet is returned with
  /// 'needs_finalization' true so the app can ask for it to be finalized. 'legacy_subject_id' is the
  /// subjects row classes use for it, when one already exists.
  static Future<List<Map<String, dynamic>>> getProgramSubjects(
    int programId,
  ) async {
    final result = await Database.pool.execute(
      Sql.named('''
        WITH base AS (
          SELECT cs.id AS slot_id, cs.subject_id, cs.year_level, cs.term,
                 cs.is_elective_slot
          FROM curricula c
          JOIN curriculum_subjects cs
            ON cs.curriculum_id = c.id AND cs.is_deleted = FALSE
          WHERE c.program_id = @program_id
            AND c.is_deleted = FALSE AND c.status = 'published'
        ),
        finalized AS (
          SELECT b.slot_id, ce.subject_id, es.school_year
          FROM base b
          JOIN elective_selections es
            ON es.curriculum_subject_id = b.slot_id AND es.is_deleted = FALSE
          JOIN curriculum_electives ce
            ON ce.id = es.elective_id AND ce.is_deleted = FALSE
          WHERE b.is_elective_slot
        ),
        program_subjects AS (
          -- regular subjects
          SELECT b.subject_id, b.year_level, b.term,
                 NULL::varchar AS school_year, FALSE AS needs_finalization
          FROM base b
          WHERE NOT b.is_elective_slot
          UNION ALL
          -- an elective slot shows the elective finalized for each school year
          SELECT f.subject_id, b.year_level, b.term,
                 f.school_year::varchar, FALSE
          FROM finalized f
          JOIN base b ON b.slot_id = f.slot_id
          UNION ALL
          -- a slot with no finalized elective yet: kept, but flagged
          SELECT b.subject_id, b.year_level, b.term,
                 NULL::varchar, TRUE
          FROM base b
          WHERE b.is_elective_slot
            AND NOT EXISTS (
              SELECT 1 FROM finalized f WHERE f.slot_id = b.slot_id
            )
        )
        SELECT a.id, a.code, a.name, a.units, ls.id, ps.year_level, ps.term,
               ps.school_year, ps.needs_finalization
        FROM program_subjects ps
        JOIN academic_subjects a
          ON a.id = ps.subject_id AND a.is_deleted = FALSE
        LEFT JOIN LATERAL (
          SELECT sub.id
          FROM subjects sub
          WHERE sub.academic_subject_id = a.id
             OR (
               sub.academic_subject_id IS NULL
               AND (
                 (a.code IS NOT NULL AND LOWER(sub.code) = LOWER(a.code))
                 OR LOWER(sub.name) = LOWER(a.name)
               )
             )
          ORDER BY (sub.academic_subject_id IS NOT NULL) DESC, sub.id
          LIMIT 1
        ) ls ON TRUE
        ORDER BY ps.year_level, ps.term, LOWER(a.name), a.code,
                 ps.school_year
      '''),
      parameters: {'program_id': programId},
    );

    return result
        .map(
          (row) => <String, dynamic>{
            'id': row[0],
            'code': row[1],
            'name': row[2],
            'units': row[3]?.toString(),
            'legacy_subject_id': row[4],
            'year_level': row[5],
            'term': row[6],
            'school_year': row[7],
            'needs_finalization': row[8],
          },
        )
        .toList();
  }

  /// Makes [items] the teacher's COMPLETE set of Subject + Section
  /// assignments, inside the caller's transaction:
  ///   * a Subject + Section already owned by ANOTHER teacher -> 409, and
  ///     nothing is changed (it is never silently taken over);
  ///   * a Subject + Section that has no class row yet is created;
  ///   * anything this teacher had before but is not in [items] is released
  ///     (teacher_id = NULL), so another teacher can take it. The class row,
  ///     its students and exams are kept.
  static Future<void> _applyAssignments(
    Session session,
    int teacherId,
    List<AssignmentInput> items,
  ) async {
    final keep = <int>{};
    final seen = <String>{};

    for (final item in items) {
      // Settle which subjects row this assignment uses, then de-duplicate
      // on teacher + subject + section + term.
      final subjectId = item.subjectId ??
          (await _legacySubjectFor(
            session,
            item.academicSubjectId!,
            create: true,
          ))!;

      final dedupeKey = '$subjectId|${item.section.toLowerCase()}|'
          '${item.schoolYear}|${item.semester}';
      if (!seen.add(dedupeKey)) continue;

      final subject = await session.execute(
        Sql.named('SELECT name FROM subjects WHERE id = @id'),
        parameters: {'id': subjectId},
      );

      if (subject.isEmpty) {
        throw TeacherException('The selected subject does not exist.');
      }

      final existing = await session.execute(
        Sql.named('''
          SELECT c.id, c.teacher_id, u.name
          FROM classes c
          LEFT JOIN users u ON u.id = c.teacher_id
          WHERE c.subject_id = @subject_id
            AND LOWER(c.section) = LOWER(@section)
            AND COALESCE(c.school_year, '') = @school_year
            AND COALESCE(c.semester, '') = @semester
          FOR UPDATE OF c
        '''),
        parameters: {
          'subject_id': subjectId,
          'section': item.section,
          'school_year': item.schoolYear,
          'semester': item.semester,
        },
      );

      if (existing.isNotEmpty) {
        final classId = existing.first[0]! as int;
        final ownerId = existing.first[1] as int?;
        final ownerName = existing.first[2] as String?;

        if (ownerId != null && ownerId != teacherId) {
          throw TeacherException(
            '${subject.first[0]} - ${item.section} is already assigned to '
            '${ownerName ?? 'another teacher'}.',
            statusCode: 409,
          );
        }

        await session.execute(
          Sql.named('UPDATE classes SET teacher_id = @t WHERE id = @id'),
          parameters: {'t': teacherId, 'id': classId},
        );

        keep.add(classId);
      } else {
        // A new Subject + Section may only use a section that exists in the
        // Sections catalog (same name, school year and semester).
        final catalog = await session.execute(
          Sql.named('''
            SELECT s.year_level
            FROM sections s
            JOIN academic_programs p
              ON p.id = s.program_id AND p.is_deleted = FALSE
            WHERE LOWER(s.name) = LOWER(@section)
              AND s.school_year = @school_year
              AND s.semester = @semester
          '''),
          parameters: {
            'section': item.section,
            'school_year': item.schoolYear,
            'semester': int.tryParse(
                  RegExp(r'^\d').firstMatch(item.semester.trim())?.group(0) ??
                      '',
                ) ??
                0,
          },
        );

        if (catalog.isEmpty) {
          throw TeacherException(
            '${item.section} (${item.schoolYear}, ${item.semester}) is not '
            'in the Sections catalog. Create it in the Sections screen '
            'first.',
          );
        }

        final created = await session.execute(
          Sql.named('''
            INSERT INTO classes (
              subject_id, teacher_id, section,
              school_year, semester, year_level
            )
            VALUES (
              @subject_id, @teacher_id, @section,
              NULLIF(@school_year, ''), NULLIF(@semester, ''),
              NULLIF(@year_level, 0)
            )
            RETURNING id
          '''),
          parameters: {
            'subject_id': subjectId,
            'teacher_id': teacherId,
            'section': item.section,
            'school_year': item.schoolYear,
            'semester': item.semester,
            'year_level': catalog.first[0] ?? 0,
          },
        );

        keep.add(created.first[0]! as int);
      }
    }

    final current = await session.execute(
      Sql.named('SELECT id FROM classes WHERE teacher_id = @id'),
      parameters: {'id': teacherId},
    );

    for (final row in current) {
      final classId = row[0]! as int;

      if (!keep.contains(classId)) {
        await session.execute(
          Sql.named('UPDATE classes SET teacher_id = NULL WHERE id = @id'),
          parameters: {'id': classId},
        );
      }
    }
  }

  static Object _mapDbError(ServerException e) {
    if (e.code == '23505') {
      final constraint = e.constraintName ?? '';

      if (constraint.contains('classes')) {
        return TeacherException(
          'That subject and section was just assigned to another teacher. '
          'Refresh and try again.',
          statusCode: 409,
        );
      }

      if (constraint.contains('teacher_id')) {
        return TeacherException(
          'This Teacher ID No. already belongs to another teacher.',
          statusCode: 409,
        );
      }

      return TeacherException(
        'That email address is already in use.',
        statusCode: 409,
      );
    }

    if (e.code == '23514') {
      return TeacherException(
        'The teacher details break a database rule (Teacher ID or email '
        'domain). Check them and try again.',
      );
    }

    return e;
  }

  // Allocate a unique, non-reusable ID within the current database year.
  // Requires migration 005. A row-level lock in the upsert serializes callers.
static Future<String> _allocateTeacherId(Session tx) async {
  final rows = await tx.execute(Sql.named('''
    INSERT INTO teacher_id_counters (year, last_number)
    VALUES (
      EXTRACT(YEAR FROM CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Manila')::INT,
      1
    )
    ON CONFLICT (year) DO UPDATE
      SET last_number = teacher_id_counters.last_number + 1
      WHERE teacher_id_counters.last_number < 9999
    RETURNING year, last_number
  '''));

  if (rows.isEmpty) {
    throw TeacherException(
      'Teacher ID limit reached for the current year.',
    );
  }

  final year = (rows.first[0]! as num).toInt();
  final number = (rows.first[1]! as num).toInt();

  return 'CM-$year-${number.toString().padLeft(4, '0')}';
}

  // ---------------------------------------------------------------
  // Password generation (server-side, cryptographically secure)
  // ---------------------------------------------------------------

  static String generatePassword({int length = 12}) {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const digits = '23456789';
    const all = upper + lower + digits;

    final rng = Random.secure();

    String pick(String chars) => chars[rng.nextInt(chars.length)];

    final chars = <String>[
      pick(upper),
      pick(lower),
      pick(digits),
      for (var i = 3; i < length; i++) pick(all),
    ]..shuffle(rng);

    return chars.join();
  }

  // ---------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> _load({int? id}) async {
    final teachers = await Database.pool.execute(
      Sql.named('''
        SELECT u.id, u.name, u.email, u.username, u.is_active,
               u.must_change_password, u.created_at,
               u.first_name, u.middle_name, u.last_name,
               u.teacher_id_no, u.department
        FROM users u
        WHERE u.role = 'teacher'
        ${id == null ? '' : 'AND u.id = @id'}
        ORDER BY LOWER(u.name), u.id
      '''),
      parameters: id == null ? null : {'id': id},
    );

    final classes = await Database.pool.execute(
      Sql.named('''
        SELECT c.id, c.section, c.school_year, c.semester, c.year_level,
               c.teacher_id, c.subject_id, s.name, s.code,
               s.academic_subject_id, pr.program_id, pr.program_code,
               pr.program_level
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
        WHERE c.teacher_id IS NOT NULL
        ORDER BY LOWER(s.name), c.year_level NULLS LAST, LOWER(c.section)
      '''),
    );

    // teacher_id -> subject_id -> {subject info, classes}
    final byTeacher = <int, Map<int, Map<String, dynamic>>>{};

    for (final row in classes) {
      final teacherId = row[5]! as int;
      final subjectId = row[6]! as int;

      final subjects = byTeacher.putIfAbsent(teacherId, () => {});
      final entry = subjects.putIfAbsent(
        subjectId,
        () => <String, dynamic>{
          'subject_id': subjectId,
          'subject_name': row[7],
          'subject_code': row[8],
          'academic_subject_id': row[9],
          'classes': <Map<String, dynamic>>[],
        },
      );

      (entry['classes'] as List<Map<String, dynamic>>).add({
        'class_id': row[0],
        'section': row[1],
        'school_year': row[2],
        'semester': row[3],
        'year_level': row[4],
        'program_id': row[10],
        'program_code': row[11],
        'program_level': row[12],
      });
    }

    return teachers.map((row) {
      final teacherId = row[0]! as int;
      final assignments = (byTeacher[teacherId] ?? {}).values.toList();

      return <String, dynamic>{
        'id': teacherId,
        'name': row[1],
        'email': row[2],
        'username': row[3],
        'is_active': row[4],
        'must_change_password': row[5],
        'assignments': assignments,
        'class_ids': [
          for (final a in assignments)
            for (final c in a['classes'] as List<Map<String, dynamic>>)
              c['class_id'],
        ],
        'created_at': row[6].toString(),
        'first_name': row[7],
        'middle_name': row[8],
        'last_name': row[9],
        'teacher_id_no': row[10],
        'department': row[11],
      };
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> getAll() => _load();

  static Future<Map<String, dynamic>> getById(int id) async {
    final rows = await _load(id: id);

    if (rows.isEmpty) {
      throw TeacherException('Teacher not found.', statusCode: 404);
    }

    return rows.first;
  }

  /// Every known section, with its status for ONE subject:
  ///   teacher_id == null  -> free (a class row may or may not exist yet)
  ///   teacher_id != null  -> already taught by that teacher
  /// The app greys out rows owned by someone other than the teacher being
  /// edited. The server re-checks on save, so this is only a convenience.
  ///
  /// Pass [academicSubjectId] (an Academic Management subject) and/or
  /// [programId] to narrow it to one program's sections, and [yearLevel] /
  /// [term] to the year and semester the subject is taught in.
  static Future<List<Map<String, dynamic>>> getTeachingOptions(
    int? subjectId, {
    int? academicSubjectId,
    int? programId,
    int? yearLevel,
    int? term,
    String? schoolYear,
  }) async {
    var legacySubjectId = subjectId;
    if (legacySubjectId == null && academicSubjectId != null) {
      legacySubjectId = await _legacySubjectFor(
        Database.pool,
        academicSubjectId,
        create: false,
      );
    }

    // Options come from the Sections catalog (the `sections` table managed
    // in the Sections screen), never from free-text class names. Semester is
    // shown as "1st Semester" / "2nd Semester", the format classes store.
    final result = await Database.pool.execute(
      Sql.named('''
        WITH catalog AS (
          SELECT s.name AS section,
                 s.school_year,
                 CASE s.semester
                   WHEN 1 THEN '1st Semester'
                   WHEN 2 THEN '2nd Semester'
                   ELSE s.semester::text
                 END AS semester,
                 s.year_level,
                 s.semester AS term_no,
                 s.program_id,
                 p.code AS program_code,
                 p.level AS program_level
          FROM sections s
          JOIN academic_programs p
            ON p.id = s.program_id AND p.is_deleted = FALSE
        )
        SELECT s.section, s.school_year, s.semester, s.year_level,
               c.id, c.teacher_id, u.name,
               s.program_code, s.program_level, s.program_id
        FROM catalog s
        LEFT JOIN classes c
               ON c.subject_id = @subject_id
              AND LOWER(c.section) = LOWER(s.section)
              AND COALESCE(c.school_year, '') = s.school_year
              AND COALESCE(c.semester, '') = s.semester
        LEFT JOIN users u ON u.id = c.teacher_id
        WHERE (@program_id::bigint IS NULL OR s.program_id = @program_id)
          AND (@year_level::int IS NULL OR s.year_level = @year_level)
          AND (@term::int IS NULL OR s.term_no = @term)
          AND (@school_year::text IS NULL OR s.school_year = @school_year::text)
        ORDER BY s.program_level, s.program_code, s.year_level,
                 LOWER(s.section)
      '''),
      parameters: {
        // -1 matches no class: the subject has no classes yet.
        'subject_id': legacySubjectId ?? -1,
        'program_id': programId,
        'year_level': yearLevel,
        'term': term,
        'school_year': schoolYear,
      },
    );

    return result.map((row) {
      return <String, dynamic>{
        'section': row[0],
        'school_year': row[1],
        'semester': row[2],
        'year_level': row[3],
        'class_id': row[4],
        'teacher_id': row[5],
        'teacher_name': row[6],
        'program_code': row[7],
        'program_level': row[8],
        'program_id': row[9],
      };
    }).toList();
  }

  // ---------------------------------------------------------------
  // Create
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> create({
    required String firstName,
    required String middleName,
    required String lastName,
    required String department,
    required String temporaryPassword,
    List<AssignmentInput> assignments = const [],
  }) async {
    if (temporaryPassword.length < 8) {
      throw TeacherException(
        'Temporary password must be at least 8 characters.',
      );
    }

    final passwordHash = Password.hash(temporaryPassword);

    try {
      final id = await Database.pool.runTx((tx) async {
        final teacherIdNo = await _allocateTeacherId(tx);
        final who = TeacherIdentity.validate(
          teacherIdNo: teacherIdNo,
          firstName: firstName,
          middleName: middleName,
          lastName: lastName,
          department: department,
        );
        await _assertUnique(
          tx,
          teacherIdNo: who.teacherIdNo,
          email: who.email,
        );

        // The institutional email is also the login username.
        final result = await tx.execute(
          Sql.named('''
            INSERT INTO users (
              name, first_name, middle_name, last_name,
              teacher_id_no, department,
              email, username, password_hash, role,
              is_active, must_change_password
            )
            VALUES (
              @name, @first_name, NULLIF(@middle_name, ''), @last_name,
              @teacher_id_no, @department,
              @email, @email, @hash, 'teacher',
              TRUE, TRUE
            )
            RETURNING id
          '''),
          parameters: {
            'name': who.fullName,
            'first_name': who.firstName,
            'middle_name': who.middleName,
            'last_name': who.lastName,
            'teacher_id_no': who.teacherIdNo,
            'department': who.department,
            'email': who.email,
            'hash': passwordHash,
          },
        );

        final newId = result.first[0]! as int;

        await _applyAssignments(tx, newId, assignments);

        return newId;
      });

      return await getById(id);
    } on ServerException catch (e) {
      throw _mapDbError(e);
    }
  }

  // ---------------------------------------------------------------
  // Update profile (never touches the password or an assigned Teacher ID).
  // Editing a legacy profile with a NULL ID allocates one.
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> update({
    required int id,
    required String firstName,
    required String middleName,
    required String lastName,
    required String department,
    bool? isActive,
    List<AssignmentInput>? assignments,
  }) async {
    try {
      await Database.pool.runTx((tx) async {
        await _requireTeacher(tx, id);
        final existing = await tx.execute(
          Sql.named('SELECT teacher_id_no FROM users WHERE id = @id'),
          parameters: {'id': id},
        );
        final oldId = existing.first[0] as String?;
        final teacherIdNo = oldId == null || oldId.isEmpty
            ? await _allocateTeacherId(tx)
            : oldId;
        final who = TeacherIdentity.validate(
          teacherIdNo: teacherIdNo,
          firstName: firstName,
          middleName: middleName,
          lastName: lastName,
          department: department,
        );
        await _assertUnique(
          tx,
          teacherIdNo: who.teacherIdNo,
          email: who.email,
          excludeId: id,
        );

        await tx.execute(
          Sql.named('''
            UPDATE users
            SET name = @name,
                first_name = @first_name,
                middle_name = NULLIF(@middle_name, ''),
                last_name = @last_name,
                teacher_id_no = @teacher_id_no,
                department = @department,
                email = @email,
                username = @email,
                ${isActive == null ? '' : 'is_active = @active,'}
                updated_at = NOW()
            WHERE id = @id
          '''),
          parameters: {
            'id': id,
            'name': who.fullName,
            'first_name': who.firstName,
            'middle_name': who.middleName,
            'last_name': who.lastName,
            'teacher_id_no': who.teacherIdNo,
            'department': who.department,
            'email': who.email,
            if (isActive != null) 'active': isActive,
          },
        );

        // Only touch assignments when the app sent them (atomic with the
        // profile edit: a conflict rolls the whole save back).
        if (assignments != null) {
          await _applyAssignments(tx, id, assignments);
        }
      });

      return await getById(id);
    } on ServerException catch (e) {
      throw _mapDbError(e);
    }
  }

  // ---------------------------------------------------------------
  // Assignments (replaces the teacher's full set of Subject + Section)
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> setAssignments({
    required int id,
    required List<AssignmentInput> assignments,
  }) async {
    try {
      await Database.pool.runTx((tx) async {
        await _requireTeacher(tx, id);
        await _applyAssignments(tx, id, assignments);
      });

      return await getById(id);
    } on ServerException catch (e) {
      throw _mapDbError(e);
    }
  }

  // ---------------------------------------------------------------
  // Reset password -> returns the new temporary password ONCE
  // ---------------------------------------------------------------

  static Future<String> resetPassword(int id) async {
    final password = generatePassword();
    final hash = Password.hash(password);

    await Database.pool.runTx((tx) async {
      await _requireTeacher(tx, id);

      await tx.execute(
        Sql.named('''
          UPDATE users
          SET password_hash = @hash,
              must_change_password = TRUE,
              updated_at = NOW()
          WHERE id = @id
        '''),
        parameters: {'hash': hash, 'id': id},
      );
    });

    return password;
  }

  // ---------------------------------------------------------------
  // Enable / disable
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> setActive({
    required int id,
    required bool active,
  }) async {
    await Database.pool.runTx((tx) async {
      await _requireTeacher(tx, id);

      await tx.execute(
        Sql.named('''
          UPDATE users
          SET is_active = @active, updated_at = NOW()
          WHERE id = @id
        '''),
        parameters: {'active': active, 'id': id},
      );
    });

    return getById(id);
  }

  // ---------------------------------------------------------------
  // Delete (sections stay, unassigned)
  // ---------------------------------------------------------------

  /// Returns how many Subject + Section assignments were released.
  /// Sections, students and exams are never deleted: the sections simply
  /// become unassigned (teacher_id = NULL) and can be given to someone else.
  static Future<int> delete(int id) async {
    return Database.pool.runTx((tx) async {
      await _requireTeacher(tx, id);

      final released = await tx.execute(
        Sql.named(
          'UPDATE classes SET teacher_id = NULL WHERE teacher_id = @id '
          'RETURNING id',
        ),
        parameters: {'id': id},
      );

      await tx.execute(
        Sql.named("DELETE FROM users WHERE id = @id AND role = 'teacher'"),
        parameters: {'id': id},
      );

      return released.length;
    });
  }
}
