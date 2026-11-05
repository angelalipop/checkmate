import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

/// An error whose [message] is safe to show to the teacher (HTTP 400).
class ExamValidationException implements Exception {
  ExamValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ExamService {
  static const assessmentTypes = <String>{
    'quiz',
    'long_quiz',
    'prelim',
    'midterm',
    'prefinal',
    'final',
  };

  static List<int> _parseIds(Object? raw) {
    return (raw?.toString() ?? '')
        .split(',')
        .map(int.tryParse)
        .whereType<int>()
        .toList();
  }

  /// When [teacherId] is given, only exams of that teacher's classes are
  /// returned (used for teacher accounts; admins pass null).
  static Future<List<Map<String, dynamic>>> getAll({
    int? classId,
    int? teacherId,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          e.id,
          e.class_id,
          e.title,
          e.description,
          e.instructions,
          e.status,
          e.created_at,
          e.updated_at,
          c.section,
          s.name AS subject_name,
          s.code AS subject_code,
          e.assessment_type,
          e.version,
          (
            SELECT string_agg(q.cid::text, ',' ORDER BY q.cid)
            FROM (
              SELECT x.class_id AS cid
              FROM exam_class_assignments x
              WHERE x.exam_id = e.id
              UNION
              SELECT e.class_id
            ) q
          ) AS class_ids
        FROM exams e
        JOIN classes c ON c.id = e.class_id
        JOIN subjects s ON s.id = c.subject_id
        WHERE (
          @class_id::bigint IS NULL
          OR e.class_id = @class_id
        )
        AND (
          @teacher_id::bigint IS NULL
          OR c.teacher_id = @teacher_id
        )
        ORDER BY e.created_at DESC
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
        'title': row[2],
        'description': row[3],
        'instructions': row[4],
        'status': row[5],
        'created_at': row[6].toString(),
        'updated_at': row[7].toString(),
        'assessment_type': row[11],
        'version': row[12],
        // Every section (class) this exam is given to.
        'class_ids': _parseIds(row[13]),
        'class': {
          'id': row[1],
          'section': row[8],
          'subject': {
            'name': row[9],
            'code': row[10],
          },
        },
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int classId,
    required String title,
    String? description,
    String? instructions,
    String? status,
  }) async {
    final normalizedStatus =
        status?.trim().toLowerCase();

    const allowedStatuses = {
      'draft',
      'published',
      'archived',
    };

    if (normalizedStatus != null &&
        !allowedStatuses.contains(normalizedStatus)) {
      throw Exception(
        'Invalid exam status. '
        'Use draft, published, or archived.',
      );
    }

    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO exams (
          class_id,
          title,
          description,
          instructions,
          status
        )
        VALUES (
          @class_id,
          @title,
          @description,
          @instructions,
          COALESCE(@status, 'draft')
        )
        RETURNING
          id,
          class_id,
          title,
          description,
          instructions,
          status,
          created_at,
          updated_at
      '''),
      parameters: {
        'class_id': classId,
        'title': title.trim(),
        'description':
            description?.trim().isEmpty ?? false
                ? null
                : description?.trim(),
        'instructions':
            instructions?.trim().isEmpty ?? false
                ? null
                : instructions?.trim(),
        'status': normalizedStatus,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'class_id': row[1],
      'title': row[2],
      'description': row[3],
      'instructions': row[4],
      'status': row[5],
      'created_at': row[6].toString(),
      'updated_at': row[7].toString(),
    };
  }

  /// Updates title / description / instructions / assessment type and,
  /// optionally, the sections (classes) the exam is given to.
  ///
  /// Returns null when the exam is not found or the user may not edit it.
  /// Throws [ExamValidationException] for bad input.
  ///
  /// Sections ([classIds]) can only be changed on a DRAFT exam that has no
  /// attempts. Every chosen section must belong to the same subject as the
  /// exam, and a teacher can only choose their own sections.
  /// The old single [classId] is still accepted (it means "only this
  /// section").
  static Future<Map<String, dynamic>?> update(
    int id, {
    required int userId,
    required String role,
    required String title,
    String? description,
    String? instructions,
    int? classId,
    List<int>? classIds,
    String? assessmentType,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw ExamValidationException('Exam title is required.');
    }

    final typeText = assessmentType?.trim().toLowerCase();
    final type = (typeText == null || typeText.isEmpty) ? null : typeText;
    if (type != null && !assessmentTypes.contains(type)) {
      throw ExamValidationException('Choose a valid assessment type.');
    }

    final requested = classIds != null
        ? classIds.toSet()
        : (classId != null ? <int>{classId} : null);
    if (requested != null && requested.isEmpty) {
      throw ExamValidationException('Choose at least one section.');
    }
    if (requested != null && requested.length > 30) {
      throw ExamValidationException('Too many sections selected.');
    }

    String? clean(String? v) =>
        (v == null || v.trim().isEmpty) ? null : v.trim();

    return Database.pool.runTx<Map<String, dynamic>?>((tx) async {
      final found = await tx.execute(
        Sql.named('''
          SELECT e.class_id, e.status, c.teacher_id, c.subject_id,
                 EXISTS (
                   SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id
                 )
          FROM exams e
          JOIN classes c ON c.id = e.class_id
          WHERE e.id = @id
          FOR UPDATE OF e
        '''),
        parameters: {'id': id},
      );

      if (found.isEmpty) return null;

      final cur = found.first;
      final currentClassId = cur[0]! as int;
      final status = cur[1]! as String;
      final ownerId = cur[2] as int?;
      final subjectId = cur[3]! as int;
      final hasAttempts = cur[4]! as bool;

      // Same rule as before: admins, or the teacher who owns the exam.
      if (role != 'admin' && ownerId != userId) return null;

      final assignedRows = await tx.execute(
        Sql.named(
          'SELECT class_id FROM exam_class_assignments WHERE exam_id = @id',
        ),
        parameters: {'id': id},
      );

      final current = <int>{
        currentClassId,
        for (final r in assignedRows) r[0]! as int,
      };

      var finalIds = current;
      var newPrimary = currentClassId;

      if (requested != null &&
          !(requested.length == current.length &&
              requested.containsAll(current))) {
        if (status != 'draft' || hasAttempts) {
          throw ExamValidationException(
            'Sections can only be changed while the exam is a draft '
            'with no student attempts.',
          );
        }

        final rows = await tx.execute(
          Sql.named(
            'SELECT id, subject_id, teacher_id FROM classes '
            'WHERE id = ANY(@ids)',
          ),
          parameters: {
            'ids': TypedValue(Type.bigIntegerArray, requested.toList()),
          },
        );

        if (rows.length != requested.length) {
          throw ExamValidationException('Section not found.');
        }

        for (final r in rows) {
          if ((r[1]! as int) != subjectId) {
            throw ExamValidationException(
              'An exam can only be given to sections of the same subject.',
            );
          }
          if (role != 'admin' && r[2] != userId) {
            throw ExamValidationException(
              'You are not assigned to one of the selected sections.',
            );
          }
        }

        final sorted = requested.toList()..sort();
        newPrimary =
            requested.contains(currentClassId) ? currentClassId : sorted.first;

        await tx.execute(
          Sql.named('''
            DELETE FROM exam_class_assignments
            WHERE exam_id = @id AND NOT (class_id = ANY(@ids))
          '''),
          parameters: {
            'id': id,
            'ids': TypedValue(Type.bigIntegerArray, sorted),
          },
        );

        for (final cid in sorted) {
          await tx.execute(
            Sql.named('''
              INSERT INTO exam_class_assignments
                (exam_id, class_id, exam_version, assigned_by)
              SELECT e.id, @class_id::bigint, e.version, @user_id::bigint
              FROM exams e
              WHERE e.id = @id
              ON CONFLICT (exam_id, class_id) DO NOTHING
            '''),
            parameters: {'id': id, 'class_id': cid, 'user_id': userId},
          );
        }

        finalIds = requested;
      }

      final updated = await tx.execute(
        Sql.named('''
          UPDATE exams
          SET
            title = @title,
            description = @description,
            instructions = @instructions,
            class_id = @class_id,
            assessment_type = COALESCE(@type::text, assessment_type),
            updated_at = NOW()
          WHERE id = @id
          RETURNING
            id,
            class_id,
            title,
            description,
            instructions,
            status,
            created_at,
            updated_at,
            assessment_type,
            version
        '''),
        parameters: {
          'id': id,
          'title': cleanTitle,
          'description': clean(description),
          'instructions': clean(instructions),
          'class_id': newPrimary,
          'type': type,
        },
      );

      final row = updated.first;

      return {
        'id': row[0],
        'class_id': row[1],
        'title': row[2],
        'description': row[3],
        'instructions': row[4],
        'status': row[5],
        'created_at': row[6].toString(),
        'updated_at': row[7].toString(),
        'assessment_type': row[8],
        'version': row[9],
        'class_ids': (finalIds.toList()..sort()),
      };
    });
  }
}
