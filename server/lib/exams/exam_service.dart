import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class ExamService {
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
          s.code AS subject_code
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

  /// Updates title / description / instructions (and optionally the class).
  /// Returns null when the exam is not found or the user may not edit it.
  /// Moving an exam to another class is only allowed for a draft exam that
  /// has no attempts, and a teacher can only move it to one of their classes.
  static Future<Map<String, dynamic>?> update(
    int id, {
    required int userId,
    required String role,
    required String title,
    String? description,
    String? instructions,
    int? classId,
  }) async {
    if (title.trim().isEmpty) {
      throw Exception('Exam title is required.');
    }

    final result = await Database.pool.execute(
      Sql.named('''
        UPDATE exams AS e
        SET
          title = @title,
          description = @description,
          instructions = @instructions,
          class_id = COALESCE(@class_id::bigint, e.class_id),
          updated_at = NOW()
        FROM classes AS c
        WHERE e.id = @id
          AND c.id = e.class_id
          AND (@role = 'admin' OR (@role = 'teacher' AND c.teacher_id = @user_id))
          AND (
            @class_id::bigint IS NULL
            OR @class_id::bigint = e.class_id
            OR (
              e.status = 'draft'
              AND NOT EXISTS (
                SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id
              )
              AND (
                @role = 'admin'
                OR EXISTS (
                  SELECT 1 FROM classes c2
                  WHERE c2.id = @class_id::bigint AND c2.teacher_id = @user_id
                )
              )
            )
          )
        RETURNING
          e.id,
          e.class_id,
          e.title,
          e.description,
          e.instructions,
          e.status,
          e.created_at,
          e.updated_at
      '''),
      parameters: {
        'id': id,
        'user_id': userId,
        'role': role,
        'title': title.trim(),
        'description': (description?.trim().isEmpty ?? true)
            ? null
            : description!.trim(),
        'instructions': (instructions?.trim().isEmpty ?? true)
            ? null
            : instructions!.trim(),
        'class_id': classId,
      },
    );

    if (result.isEmpty) return null;

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
}
