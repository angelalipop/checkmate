import 'dart:math';

import 'package:postgres/postgres.dart';

import 'package:server/auth/password.dart';
import 'package:server/classes/class_service.dart';
import 'package:server/database.dart';

class TeacherException implements Exception {
  TeacherException(this.message, {this.statusCode = 400});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

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
  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  // No '@' allowed, so a username can never be confused with an email
  // when logging in with either.
  static final _usernameRegex = RegExp(r'^[a-z0-9][a-z0-9._-]{2,99}$');

  // ---------------------------------------------------------------
  // Validation helpers
  // ---------------------------------------------------------------

  static ({String name, String email, String username}) _validateProfile({
    required String name,
    required String email,
    required String username,
  }) {
    final cleanName = name.trim();
    final cleanEmail = email.trim().toLowerCase();
    final cleanUsername = username.trim().toLowerCase();

    if (cleanName.isEmpty) {
      throw TeacherException('Full name is required.');
    }

    if (cleanEmail.isEmpty || !_emailRegex.hasMatch(cleanEmail)) {
      throw TeacherException('A valid email address is required.');
    }

    if (cleanUsername.isEmpty) {
      throw TeacherException('Username is required.');
    }

    if (!_usernameRegex.hasMatch(cleanUsername)) {
      throw TeacherException(
        'Username must be 3-100 characters: letters, numbers, '
        'dots, dashes or underscores.',
      );
    }

    return (name: cleanName, email: cleanEmail, username: cleanUsername);
  }

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
    required String email,
    required String username,
    int excludeId = -1,
  }) async {
    final result = await session.execute(
      Sql.named('''
        SELECT (LOWER(email) = LOWER(@email)) AS email_match,
               (LOWER(username) = LOWER(@username)) AS username_match
        FROM users
        WHERE (LOWER(email) = LOWER(@email)
               OR LOWER(username) = LOWER(@username))
          AND id <> @exclude_id
      '''),
      parameters: {
        'email': email,
        'username': username,
        'exclude_id': excludeId,
      },
    );

    for (final row in result) {
      if (row[0] == true) {
        throw TeacherException(
          'A user with this email already exists.',
          statusCode: 409,
        );
      }
    }

    for (final row in result) {
      if (row[1] == true) {
        throw TeacherException(
          'This username is already taken.',
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

      return TeacherException(
        'That email or username is already in use.',
        statusCode: 409,
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
               u.must_change_password, u.created_at
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
    required String name,
    required String email,
    required String username,
    required String temporaryPassword,
    List<AssignmentInput> assignments = const [],
  }) async {
    final profile = _validateProfile(
      name: name,
      email: email,
      username: username,
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
          email: profile.email,
          username: profile.username,
        );

        final result = await tx.execute(
          Sql.named('''
            INSERT INTO users (
              name, email, password_hash, role, username,
              is_active, must_change_password
            )
            VALUES (
              @name, @email, @hash, 'teacher', @username,
              TRUE, TRUE
            )
            RETURNING id
          '''),
          parameters: {
            'name': profile.name,
            'email': profile.email,
            'hash': passwordHash,
            'username': profile.username,
          },
        );

        final newId = result.first[0]! as int;

        await _applyAssignments(tx, newId, assignments);

        return newId;
      });

      return getById(id);
    } on ServerException catch (e) {
      throw _mapDbError(e);
    }
  }

  // ---------------------------------------------------------------
  // Update profile (never touches the password)
  // ---------------------------------------------------------------

  static Future<Map<String, dynamic>> update({
    required int id,
    required String name,
    required String email,
    required String username,
    List<AssignmentInput>? assignments,
  }) async {
    final profile = _validateProfile(
      name: name,
      email: email,
      username: username,
    );

    try {
      await Database.pool.runTx((tx) async {
        await _requireTeacher(tx, id);
        await _assertUnique(
          tx,
          email: profile.email,
          username: profile.username,
          excludeId: id,
        );

        await tx.execute(
          Sql.named('''
            UPDATE users
            SET name = @name,
                email = @email,
                username = @username,
                updated_at = NOW()
            WHERE id = @id
          '''),
          parameters: {
            'id': id,
            'name': profile.name,
            'email': profile.email,
            'username': profile.username,
          },
        );

        // Only touch assignments when the app sent them (atomic with the
        // profile edit: a conflict rolls the whole save back).
        if (assignments != null) {
          await _applyAssignments(tx, id, assignments);
        }
      });

      return getById(id);
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

      return getById(id);
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

  static Future<void> delete(int id) async {
    await Database.pool.runTx((tx) async {
      await _requireTeacher(tx, id);

      await tx.execute(
        Sql.named('UPDATE classes SET teacher_id = NULL WHERE teacher_id = @id'),
        parameters: {'id': id},
      );

      await tx.execute(
        Sql.named("DELETE FROM users WHERE id = @id AND role = 'teacher'"),
        parameters: {'id': id},
      );
    });
  }
}
