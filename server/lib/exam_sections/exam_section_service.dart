import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class ExamSectionService {
  static const allowedQuestionTypes = <String>{
    'multiple_choice',
    'true_false',
    'identification',
  };

  static Future<List<Map<String, dynamic>>> getByExam(
    int examId,
  ) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          id,
          exam_id,
          name,
          question_type,
          section_order,
          default_points
        FROM exam_sections
        WHERE exam_id = @exam_id
        ORDER BY section_order, id
      '''),
      parameters: {
        'exam_id': examId,
      },
    );

    return result.map((row) {
      return {
        'id': row[0],
        'exam_id': row[1],
        'name': row[2],
        'question_type': row[3],
        'section_order': row[4],
        'default_points': row[5].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int examId,
    required String name,
    required String questionType,
    required int sectionOrder,
    required num defaultPoints,
  }) async {
    final normalizedQuestionType = questionType.trim().toLowerCase();

    if (!allowedQuestionTypes.contains(
      normalizedQuestionType,
    )) {
      throw Exception(
        'Invalid question type. '
        'Use multiple_choice, true_false, or identification.',
      );
    }

    if (name.trim().isEmpty) {
      throw Exception(
        'Section name is required.',
      );
    }

    if (sectionOrder < 1) {
      throw Exception(
        'Section order must be at least 1.',
      );
    }

    if (defaultPoints < 0) {
      throw Exception(
        'Default points cannot be negative.',
      );
    }

    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO exam_sections (
          exam_id,
          name,
          question_type,
          section_order,
          default_points
        )
        VALUES (
          @exam_id,
          @name,
          @question_type,
          @section_order,
          @default_points
        )
        RETURNING
          id,
          exam_id,
          name,
          question_type,
          section_order,
          default_points
      '''),
      parameters: {
        'exam_id': examId,
        'name': name.trim(),
        'question_type': normalizedQuestionType,
        'section_order': sectionOrder,
        'default_points': defaultPoints,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'exam_id': row[1],
      'name': row[2],
      'question_type': row[3],
      'section_order': row[4],
      'default_points': row[5].toString(),
    };
  }

  static Future<bool> deleteDraftSection(
    int id, {
    required int userId,
    required String role,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
DELETE FROM exam_sections AS s
          USING exams AS e, classes AS c
          WHERE s.id = @id AND e.id = s.exam_id AND c.id = e.class_id
            AND (@role = 'admin' OR (@role = 'teacher' AND c.teacher_id = @user_id))
            AND e.status = 'draft'
            AND NOT EXISTS (SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id)
          RETURNING s.id'''),
      parameters: {'id': id, 'user_id': userId, 'role': role},
    );
    return result.isNotEmpty;
  }

  /// Renames a section / changes its default points and optionally its
  /// question type on a draft exam with no attempts.
  static Future<Map<String, dynamic>?> updateDraftSection(
    int id, {
    required int userId,
    required String role,
    required String name,
    required num defaultPoints,
    String? questionType,
  }) async {
    if (name.trim().isEmpty) {
      throw Exception('Section name is required.');
    }

    if (defaultPoints <= 0) {
      throw Exception('Default points must be greater than zero.');
    }

    String? normalizedType;
    if (questionType != null && questionType.trim().isNotEmpty) {
      normalizedType = questionType.trim().toLowerCase();
      if (!allowedQuestionTypes.contains(normalizedType)) {
        throw Exception(
          'Invalid question type. Use multiple_choice, true_false, or identification.',
        );
      }
    }

    final result = await Database.pool.execute(
      Sql.named('''
        UPDATE exam_sections AS s
        SET
          name = @name,
          default_points = @default_points,
          question_type = COALESCE(@question_type::text, s.question_type)
        FROM exams AS e, classes AS c
        WHERE s.id = @id AND e.id = s.exam_id AND c.id = e.class_id
          AND (@role = 'admin' OR (@role = 'teacher' AND c.teacher_id = @user_id))
          AND e.status = 'draft'
          AND NOT EXISTS (SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id)
        RETURNING
          s.id,
          s.exam_id,
          s.name,
          s.question_type,
          s.section_order,
          s.default_points
      '''),
      parameters: {
        'id': id,
        'user_id': userId,
        'role': role,
        'name': name.trim(),
        'default_points': defaultPoints,
        'question_type': normalizedType,
      },
    );

    if (result.isEmpty) return null;

    final row = result.first;

    return {
      'id': row[0],
      'exam_id': row[1],
      'name': row[2],
      'question_type': row[3],
      'section_order': row[4],
      'default_points': row[5].toString(),
    };
  }
}
