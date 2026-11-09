import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

/// An expected, user-facing failure of the one-time student edit.
class StudentEditException implements Exception {
  StudentEditException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class StudentEmailException implements Exception {
  StudentEmailException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

// BULK STUDENT EMAILS
class StudentService {
  static String _normSection(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  // ---------------------------------------------------------------
  // BULK STUDENT EMAILS
  // ---------------------------------------------------------------
  static Future<Map<String, dynamic>> updateEmailsForSection({
    required String section,
    required List<Map<String, dynamic>> updates,
    int? teacherId,
  }) async {
    final targetSection = section.trim();

    if (targetSection.isEmpty) {
      throw StudentEmailException(400, 'Section is required.');
    }

    if (updates.isEmpty) {
      throw StudentEmailException(400, 'No student emails were submitted.');
    }

    if (updates.length > 500) {
      throw StudentEmailException(
        400,
        'A maximum of 500 students can be saved at once.',
      );
    }

    final requested = <String, String?>{};
    final emailOwners = <String, Set<String>>{};
    final duplicateStudentKeys = <String>{};
    final errors = <Map<String, dynamic>>[];

    for (final item in updates) {
      final studentNumber = item['student_number']?.toString().trim() ?? '';

      final key = studentNumber.toUpperCase();

      if (key.isEmpty) {
        errors.add({
          'student_number': '',
          'message': 'Student number is required.',
        });
        continue;
      }

      if (requested.containsKey(key)) {
        throw StudentEmailException(
          400,
          'Student number $studentNumber was submitted more than once.',
        );
      }

      final rawEmail = item['email']?.toString().trim() ?? '';
      final email = rawEmail.isEmpty ? null : rawEmail;

      requested[key] = email;

      if (email == null) continue;

      if (email.length > 255 || !_emailRe.hasMatch(email)) {
        errors.add({
          'student_number': studentNumber,
          'message': 'Invalid email address.',
        });
        continue;
      }

      final emailKey = email.toLowerCase();
      emailOwners.putIfAbsent(emailKey, () => <String>{});
      emailOwners[emailKey]!.add(key);
    }

    // Identify duplicate emails and skip every affected student.
    for (final entry in emailOwners.entries) {
      if (entry.value.length > 1) {
        for (final studentKey in entry.value) {
          duplicateStudentKeys.add(studentKey);
          errors.add({
            'student_number': studentKey,
            'message': 'Email ${entry.key} is assigned to multiple students.',
          });
        }
      }
    }

    // Continue with the database transaction.
    return Database.pool.runTx((tx) async {
      // 1. Find classes belonging to the requested section.
      final classes = await tx.execute(
        Sql.named('''
          SELECT id, section
          FROM classes
          WHERE (
            @teacher_id::bigint IS NULL
            OR teacher_id = @teacher_id
          )
        '''),
        parameters: {
          'teacher_id': teacherId,
        },
      );

      final classIds = <int>[];

      for (final row in classes) {
        final classSection = row[1]?.toString() ?? '';

        if (isSameSection(classSection, targetSection)) {
          classIds.add(row[0]! as int);
        }
      }

      if (classIds.isEmpty) {
        throw StudentEmailException(
          404,
          'No accessible classes were found for section $targetSection.',
        );
      }

      // 2. Lock and retrieve students in those classes.
      final studentRows = await tx.execute(
        Sql.named('''
          SELECT
            s.id,
            s.student_number,
            s.email
          FROM students s
          WHERE s.class_id = ANY(@class_ids)
          FOR UPDATE
        '''),
        parameters: {
          'class_ids': TypedValue(Type.bigIntegerArray, classIds),
        },
      );

      final studentIds = <String, List<int>>{};

      for (final row in studentRows) {
        final number = row[1]?.toString().trim().toUpperCase() ?? '';

        if (number.isEmpty) continue;

        studentIds.putIfAbsent(number, () => []);
        studentIds[number]!.add(row[0]! as int);
      }
      // Reject the entire save if an unknown student number belongs
      // to a different section.
      final unknownNumbers = requested.keys
          .where((number) => !studentIds.containsKey(number))
          .toList();

      if (unknownNumbers.isNotEmpty) {
        final parameters = <String, Object?>{};
        final placeholders = <String>[];

        for (var i = 0; i < unknownNumbers.length; i++) {
          final parameterName = 'number_$i';
          parameters[parameterName] = unknownNumbers[i];
          placeholders.add('@$parameterName');
        }

        final otherSections = await tx.execute(
          Sql.named('''
      SELECT DISTINCT c.section
      FROM students s
      JOIN classes c ON c.id = s.class_id
      WHERE UPPER(BTRIM(s.student_number)) IN (${placeholders.join(', ')})
    '''),
          parameters: parameters,
        );

        final belongsElsewhere = otherSections.any(
          (row) {
            final otherSection = row[0]?.toString().trim() ?? '';
            return otherSection.isNotEmpty &&
                !isSameSection(otherSection, targetSection);
          },
        );

        if (belongsElsewhere) {
          throw StudentEmailException(
            409,
            'The uploaded file contains students assigned to another section. No emails were saved.',
          );
        }
      }
      // 3. Identify unknown student numbers.
      final validUpdates = <String, String?>{};

      for (final entry in requested.entries) {
        if (duplicateStudentKeys.contains(entry.key)) {
          continue;
        }
        if (!studentIds.containsKey(entry.key)) {
          errors.add({
            'student_number': entry.key,
            'message': 'Student was not found in section $targetSection.',
          });
          continue;
        }

        final email = entry.value;

        if (email != null &&
            (email.length > 255 || !_emailRe.hasMatch(email))) {
          continue;
        }

        validUpdates[entry.key] = email;
      }

      // 4. Check whether submitted emails belong to other students.
      final emailsToCheck = validUpdates.values
          .whereType<String>()
          .map((email) => email.toLowerCase())
          .toSet()
          .toList();

      final existingOwners = <String, Set<String>>{};

      if (emailsToCheck.isNotEmpty) {
        final parameters = <String, Object?>{};
        final placeholders = <String>[];

        for (var i = 0; i < emailsToCheck.length; i++) {
          final parameterName = 'email_$i';
          parameters[parameterName] = emailsToCheck[i];
          placeholders.add('@$parameterName');
        }

        final existing = await tx.execute(
          Sql.named('''
            SELECT student_number, email
            FROM students
            WHERE LOWER(BTRIM(email)) IN (${placeholders.join(', ')})
          '''),
          parameters: parameters,
        );

        for (final row in existing) {
          final number = row[0]?.toString().trim().toUpperCase() ?? '';
          final email = row[1]?.toString().trim().toLowerCase() ?? '';

          existingOwners.putIfAbsent(email, () => <String>{});
          existingOwners[email]!.add(number);
        }
      }

      // 5. Save valid updates across all subject records in the section.
      var updatedCount = 0;
      var unchangedCount = 0;

      for (final entry in validUpdates.entries) {
        final number = entry.key;
        final email = entry.value;

        final emailKey = email?.toLowerCase();

        if (emailKey != null) {
          final owners = existingOwners[emailKey] ?? <String>{};

          final hasOtherOwner = owners.any(
            (owner) => owner != number,
          );

          if (hasOtherOwner) {
            errors.add({
              'student_number': number,
              'message': 'Email $email is already assigned to another student.',
            });
            continue;
          }
        }

        final ids = studentIds[number]!;

        final result = await tx.execute(
          Sql.named('''
            UPDATE students
            SET email = @email
            WHERE id = ANY(@ids)
              AND email IS DISTINCT FROM @email
            RETURNING id
          '''),
          parameters: {
            'email': email,
            'ids': TypedValue(Type.bigIntegerArray, ids),
          },
        );

        if (result.isEmpty) {
          unchangedCount++;
        } else {
          updatedCount += result.length;
        }
      }

      return {
        'updated': updatedCount,
        'unchanged': unchangedCount,
        'errors': errors,
      };
    });
  }

  /// True when [a] and [b] refer to the same section (including short-form
  /// names without the semester digit such as BSIT3A vs BSIT31A).
  static bool isSameSection(String a, String b) {
    final ka = _normSection(a);
    final kb = _normSection(b);
    if (ka == kb) return true;
    final short = RegExp(r'^([A-Z]+)(\d)([A-Z]+)$');
    final full = RegExp(r'^([A-Z]+)(\d)[12]([A-Z]+)$');
    final ma = short.firstMatch(ka);
    final fb = full.firstMatch(kb);
    if (ma != null &&
        fb != null &&
        ma[1] == fb[1] &&
        ma[2] == fb[2] &&
        ma[3] == fb[3]) {
      return true;
    }
    final mb = short.firstMatch(kb);
    final fa = full.firstMatch(ka);
    if (mb != null &&
        fa != null &&
        mb[1] == fa[1] &&
        mb[2] == fa[2] &&
        mb[3] == fa[3]) {
      return true;
    }
    return false;
  }

  /// When [teacherId] is given, only students of that teacher's classes are
  /// returned (teacher accounts; admins pass null).
  static Future<List<Map<String, dynamic>>> getAll({
    int? classId,
    int? teacherId,
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
          sub.code AS subject_code,
          s.edited_at
        FROM students s
        JOIN classes c ON c.id = s.class_id
        JOIN subjects sub ON sub.id = c.subject_id
        WHERE (
          @class_id::bigint IS NULL
          OR s.class_id = @class_id
        )
        AND (
          @teacher_id::bigint IS NULL
          OR c.teacher_id = @teacher_id
        )
        ORDER BY s.last_name, s.first_name
      '''),
      parameters: {
        'class_id': classId,
        'teacher_id': teacherId,
      },
    );

    return result.map((row) {
      return {
        'id': row[0],
        'class_id': row[1],
        'student_number': row[2],
        'first_name': row[3]?.toString().trim().toUpperCase(),
        'last_name': row[4]?.toString().trim().toUpperCase(),
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
        'edited_at': row[10]?.toString(),
      };
    }).toList();
  }

  /// Returns students enrolled in any section other than [section] across all
  /// classes, used to reject uploading a student list that already belongs to
  /// a different section while allowing the same student list on the same
  /// section for a different subject.
  /// Returns students enrolled in a different section.
  /// Teachers are limited to their assigned classes; admins pass null.
  static Future<List<Map<String, dynamic>>> getDifferentSectionStudents({
    required String section,
    int? teacherId,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT DISTINCT
          s.student_number,
          s.first_name,
          s.last_name,
          c.section
        FROM students s
        JOIN classes c ON c.id = s.class_id
        WHERE (
          @teacher_id::bigint IS NULL
          OR c.teacher_id = @teacher_id
        )
      '''),
      parameters: {
        'teacher_id': teacherId,
      },
    );

    final out = <Map<String, dynamic>>[];
    for (final row in result) {
      final otherSection = row[3]?.toString().trim() ?? '';
      if (otherSection.isEmpty || isSameSection(otherSection, section)) {
        continue;
      }
      out.add({
        'student_number': row[0],
        'first_name': row[1],
        'last_name': row[2],
        'section': otherSection,
        'class': {'section': otherSection},
      });
    }
    return out;
  }

  static Future<Map<String, dynamic>> create({
    required int classId,
    required String studentNumber,
    required String firstName,
    required String lastName,
    String? email,
  }) async {
    final cleanedNumber = studentNumber.trim();

    // 1. Check if student number already exists in this exact class (same section + same subject).
    final existingInClass = await Database.pool.execute(
      Sql.named('''
        SELECT id
        FROM students
        WHERE class_id = @class_id
          AND LOWER(BTRIM(student_number)) = LOWER(@student_number)
        LIMIT 1
      '''),
      parameters: {
        'class_id': classId,
        'student_number': cleanedNumber,
      },
    );

    if (existingInClass.isNotEmpty) {
      throw Exception(
        'A student with student number $cleanedNumber already exists in this section and subject.',
      );
    }

    // 2. Check if student number is already enrolled in a DIFFERENT section.
    // Enrolling the same student in the SAME section for a DIFFERENT subject is allowed.
    final targetClass = await Database.pool.execute(
      Sql.named('SELECT section FROM classes WHERE id = @class_id LIMIT 1'),
      parameters: {'class_id': classId},
    );

    if (targetClass.isNotEmpty) {
      final targetSection = targetClass.first[0]?.toString().trim() ?? '';
      if (targetSection.isNotEmpty) {
        final enrolledSections = await Database.pool.execute(
          Sql.named('''
            SELECT DISTINCT c.section
            FROM students s
            JOIN classes c ON c.id = s.class_id
            WHERE LOWER(BTRIM(s.student_number)) = LOWER(@student_number)
          '''),
          parameters: {'student_number': cleanedNumber},
        );

        for (final row in enrolledSections) {
          final existingSec = row[0]?.toString().trim() ?? '';
          if (existingSec.isNotEmpty &&
              !isSameSection(existingSec, targetSection)) {
            throw Exception(
              'Student $cleanedNumber is already uploaded to section $existingSec and cannot be added to $targetSection.',
            );
          }
        }
      }
    }

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
        'student_number': cleanedNumber,
        'first_name': firstName.trim().toUpperCase(),
        'last_name': lastName.trim().toUpperCase(),
        'email': email?.trim().isEmpty ?? false ? null : email?.trim(),
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

  // ---------------------------------------------------------------
  // ONE-TIME EDIT
  // ---------------------------------------------------------------

  static final _emailRe = RegExp(
    r'^[A-Za-z0-9._%+\-]+@malolos\.sti\.edu\.ph$',
    caseSensitive: false,
  );
  static final _nameRe = RegExp(r"^[\p{L}][\p{L} .'\u2019-]*$", unicode: true);

  static String _cleanName(String v) =>
      v.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();

  /// The student's class and edit status, used by the route to run its
  /// ownership check before anything is changed. Null when not found.
  static Future<Map<String, dynamic>?> findById(int id) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, class_id, edited_at
        FROM students
        WHERE id = @id
      '''),
      parameters: {'id': id},
    );

    if (result.isEmpty) return null;

    final row = result.first;
    return {
      'id': row[0],
      'class_id': row[1],
      'edited_at': row[2]?.toString(),
    };
  }

  /// Edits a student's name, student number and email, ONCE.
  ///
  /// The same student can be listed under several subjects of one section
  /// (one row per class). The edit is applied to every row that has the same
  /// student number, is in the same section, and belongs to the same teacher
  /// as the edited row, so the subjects never disagree. If any of those rows
  /// was already edited, nothing is changed.
  ///
  /// Throws [StudentEditException] for expected problems.
  static Future<Map<String, dynamic>> updateOnce({
    required int id,
    required String studentNumber,
    required String firstName,
    required String lastName,
    String? email,
  }) async {
    final newNumber = studentNumber.trim();
    final newFirst = _cleanName(firstName);
    final newLast = _cleanName(lastName);
    final trimmedEmail = email?.trim() ?? '';
    final newEmail = trimmedEmail.isEmpty ? null : trimmedEmail;

    if (newNumber.isEmpty) {
      throw StudentEditException(400, 'Student number is required.');
    }
    if (newNumber.length > 100) {
      throw StudentEditException(400, 'Student number is too long.');
    }
    if (newLast.isEmpty) {
      throw StudentEditException(400, 'Last name is required.');
    }
    if (newFirst.isEmpty) {
      throw StudentEditException(400, 'First name is required.');
    }
    if (newLast.length > 100 || newFirst.length > 100) {
      throw StudentEditException(400, 'Name is too long.');
    }
    if (!_nameRe.hasMatch(newLast) || !_nameRe.hasMatch(newFirst)) {
      throw StudentEditException(400, 'Names may only contain letters.');
    }
    return Database.pool.runTx((tx) async {
      // 1. Lock the student being edited.
      final targetResult = await tx.execute(
        Sql.named('''
          SELECT
            s.id,
            s.student_number,
            s.first_name,
            s.last_name,
            s.email,
            c.section,
            c.teacher_id
          FROM students s
          JOIN classes c ON c.id = s.class_id
          WHERE s.id = @id
          FOR UPDATE OF s
        '''),
        parameters: {'id': id},
      );

      if (targetResult.isEmpty) {
        throw StudentEditException(404, 'Student not found.');
      }

      final target = targetResult.first;
      final oldNumber = target[1]?.toString().trim() ?? '';
      final oldFirst = _cleanName(target[2]?.toString() ?? '');
      final oldLast = _cleanName(target[3]?.toString() ?? '');
      final oldEmail = target[4]?.toString().trim() ?? '';
      final emailChanged = (newEmail ?? '') != oldEmail;

      if (emailChanged &&
          newEmail != null &&
          (newEmail.length > 255 || !_emailRe.hasMatch(newEmail))) {
        throw StudentEditException(400, 'Enter a valid email address.');
      }
      final targetSection = target[5]?.toString().trim() ?? '';
      final teacherId = target[6] as int?;

      // 2. The rows that are the same student (other subjects, same section,
      //    same teacher), locked as well.
      final candidates = await tx.execute(
        Sql.named('''
          SELECT s.id, s.class_id, s.edited_at, c.section
          FROM students s
          JOIN classes c ON c.id = s.class_id
          WHERE LOWER(BTRIM(s.student_number)) = LOWER(@old_number)
            AND c.teacher_id IS NOT DISTINCT FROM @teacher_id::bigint
          FOR UPDATE OF s
        '''),
        parameters: {
          'old_number': oldNumber,
          'teacher_id': teacherId,
        },
      );

      final ids = <int>[];
      final classIds = <int>[];
      var alreadyEdited = false;

      for (final row in candidates) {
        final rowId = row[0]! as int;
        final sameSection =
            rowId == id ||
            isSameSection(row[3]?.toString() ?? '', targetSection);
        if (!sameSection) continue;
        ids.add(rowId);
        classIds.add(row[1]! as int);
        if (row[2] != null) alreadyEdited = true;
      }

      if (!ids.contains(id)) {
        ids.add(id);
      }

      // 3. One edit per student.
      if (alreadyEdited) {
        throw StudentEditException(
          409,
          "This student's details were already edited once and can no "
          'longer be changed.',
        );
      }

      // 4. Nothing changed: do not use up the one-time edit.
      final sameNumber = newNumber.toLowerCase() == oldNumber.toLowerCase();
      if (sameNumber &&
          newFirst == oldFirst &&
          newLast == oldLast &&
          (newEmail ?? '') == oldEmail) {
        throw StudentEditException(400, 'No changes to save.');
      }

      // 5. A new student number must not collide with someone else.
      if (!sameNumber) {
        final clash = await tx.execute(
          Sql.named('''
            SELECT 1
            FROM students
            WHERE class_id = ANY(@class_ids)
              AND LOWER(BTRIM(student_number)) = LOWER(@new_number)
              AND NOT (id = ANY(@ids))
            LIMIT 1
          '''),
          parameters: {
            'class_ids': TypedValue(Type.bigIntegerArray, classIds),
            'ids': TypedValue(Type.bigIntegerArray, ids),
            'new_number': newNumber,
          },
        );

        if (clash.isNotEmpty) {
          throw StudentEditException(
            409,
            'A student with student number $newNumber already exists in '
            'this section and subject.',
          );
        }

        final elsewhere = await tx.execute(
          Sql.named('''
            SELECT DISTINCT c.section
            FROM students s
            JOIN classes c ON c.id = s.class_id
            WHERE LOWER(BTRIM(s.student_number)) = LOWER(@new_number)
              AND NOT (s.id = ANY(@ids))
          '''),
          parameters: {
            'ids': TypedValue(Type.bigIntegerArray, ids),
            'new_number': newNumber,
          },
        );

        for (final row in elsewhere) {
          final otherSection = row[0]?.toString().trim() ?? '';
          if (otherSection.isNotEmpty &&
              !isSameSection(otherSection, targetSection)) {
            throw StudentEditException(
              409,
              'Student $newNumber is already uploaded to section '
              '$otherSection and cannot be used in $targetSection.',
            );
          }
        }
      }

      // 6. Apply, and lock further edits.
      final updated = await tx.execute(
        Sql.named('''
          UPDATE students
          SET
            student_number = @student_number,
            first_name = @first_name,
            last_name = @last_name,
            email = @email,
            edited_at = NOW()
          WHERE id = ANY(@ids)
          RETURNING
            id,
            class_id,
            student_number,
            first_name,
            last_name,
            email,
            created_at,
            edited_at
        '''),
        parameters: {
          'ids': TypedValue(Type.bigIntegerArray, ids),
          'student_number': newNumber,
          'first_name': newFirst,
          'last_name': newLast,
          'email': newEmail,
        },
      );

      final row = updated.firstWhere((r) => r[0] == id);

      return {
        'id': row[0],
        'class_id': row[1],
        'student_number': row[2],
        'first_name': row[3],
        'last_name': row[4],
        'email': row[5],
        'created_at': row[6].toString(),
        'edited_at': row[7]?.toString(),
      };
    });
  }
}
