import 'package:postgres/postgres.dart';

import '../database.dart';

class ExamSectionService {
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
    const allowedQuestionTypes = {
      'multiple_choice',
      'true_false',
      'identification',
    };

    final normalizedQuestionType =
        questionType.trim().toLowerCase();

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
}