import 'dart:math';

import 'package:postgres/postgres.dart';

import 'package:server/auth/password.dart';
import 'package:server/classes/class_service.dart';
import 'package:server/teachers/teacher_exception.dart';
import 'package:server/teachers/teacher_identity.dart';
import 'package:server/database.dart';

export 'package:server/teachers/teacher_exception.dart';

/// One Subject + Section the teacher teaches.
class AssignmentInput {
  AssignmentInput({
    required this.subjectId,
    required this.section,
    this.schoolYear = '',
    this.semester = '',
  });

  final int subjectId;
  final String section;
  final String schoolYear;
  final String semester;

  String get key =>
      '$subjectId|${section.toLowerCase()}|$schoolYear|$semester';
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
      final section = item['section']?.toString().trim() ?? '';

      if (subjectId == null) {
        throw TeacherException('Each assignment needs a subject.');
      }

      if (section.isEmpty) {
        throw TeacherException('Each assignment needs a section.');
      }

      out.add(
        AssignmentInput(
          subjectId: subjectId,
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
      if (!seen.add(item.key)) continue;

      final subject = await session.execute(
        Sql.named('SELECT name FROM subjects WHERE id = @id'),
        parameters: {'id': item.subjectId},
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
          'subject_id': item.subjectId,
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
            'subject_id': item.subjectId,
            'teacher_id': teacherId,
            'section': item.section,
            'school_year': item.schoolYear,
            'semester': item.semester,
            'year_level': ClassService.inferYearLevel(item.section) ?? 0,
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
               c.teacher_id, c.subject_id, s.name, s.code
        FROM classes c
        JOIN subjects s ON s.id = c.subject_id
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
          'classes': <Map<String, dynamic>>[],
        },
      );

      (entry['classes'] as List<Map<String, dynamic>>).add({
        'class_id': row[0],
        'section': row[1],
        'school_year': row[2],
        'semester': row[3],
        'year_level': row[4],
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
  static Future<List<Map<String, dynamic>>> getTeachingOptions(
    int subjectId,
  ) async {
    final result = await Database.pool.execute(
      Sql.named('''
        WITH sections AS (
          SELECT DISTINCT ON (
                   LOWER(section),
                   COALESCE(school_year, ''),
                   COALESCE(semester, '')
                 )
                 section, school_year, semester, year_level
          FROM classes
          ORDER BY LOWER(section),
                   COALESCE(school_year, ''),
                   COALESCE(semester, ''),
                   id
        )
        SELECT s.section, s.school_year, s.semester, s.year_level,
               c.id, c.teacher_id, u.name
        FROM sections s
        LEFT JOIN classes c
               ON c.subject_id = @subject_id
              AND LOWER(c.section) = LOWER(s.section)
              AND COALESCE(c.school_year, '') = COALESCE(s.school_year, '')
              AND COALESCE(c.semester, '') = COALESCE(s.semester, '')
        LEFT JOIN users u ON u.id = c.teacher_id
        ORDER BY s.year_level NULLS LAST, LOWER(s.section)
      '''),
      parameters: {'subject_id': subjectId},
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
      };
    }).toList();
  }

  // ---------------------------------------------------------------
  // Create
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> create({
    required String teacherIdNo,
    required String firstName,
    required String middleName,
    required String lastName,
    required String department,
    required String temporaryPassword,
    List<AssignmentInput> assignments = const [],
  }) async {
    final who = TeacherIdentity.validate(
      teacherIdNo: teacherIdNo,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      department: department,
    );

    if (temporaryPassword.length < 8) {
      throw TeacherException(
        'Temporary password must be at least 8 characters.',
      );
    }

    final passwordHash = Password.hash(temporaryPassword);

    try {
      final id = await Database.pool.runTx((tx) async {
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
  // Update profile (never touches the password). Changing the Teacher ID
  // or any name part regenerates the institutional email/username.
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> update({
    required int id,
    required String teacherIdNo,
    required String firstName,
    required String middleName,
    required String lastName,
    required String department,
    bool? isActive,
    List<AssignmentInput>? assignments,
  }) async {
    final who = TeacherIdentity.validate(
      teacherIdNo: teacherIdNo,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      department: department,
    );

    try {
      await Database.pool.runTx((tx) async {
        await _requireTeacher(tx, id);

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

    return await getById(id);
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
