import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../database.dart';

class QuestionService {
  static Future<List<Map<String, dynamic>>> getBySection(
    int sectionId,
  ) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          id,
          section_id,
          question_number,
          question_text,
          points,
          choices,
          correct_answer,
          created_at
        FROM questions
        WHERE section_id = @section_id
        ORDER BY question_number, id
      '''),
      parameters: {
        'section_id': sectionId,
      },
    );

    return result.map((row) {
      return {
        'id': row[0],
        'section_id': row[1],
        'question_number': row[2],
        'question_text': row[3],
        'points': row[4].toString(),
        'choices': row[5],
        'correct_answer': row[6],
        'created_at': row[7].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int sectionId,
    required int questionNumber,
    required String questionText,
    required num points,
    dynamic choices,
    String? correctAnswer,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO questions (
          section_id,
          question_number,
          question_text,
          points,
          choices,
          correct_answer
        )
        VALUES (
          @section_id,
          @question_number,
          @question_text,
          @points,
          @choices,
          @correct_answer
        )
        RETURNING
          id,
          section_id,
          question_number,
          question_text,
          points,
          choices,
          correct_answer,
          created_at
      '''),
      parameters: {
        'section_id': sectionId,
        'question_number': questionNumber,
        'question_text': questionText.trim(),
        'points': points,
        'choices': choices == null ? null : jsonEncode(choices),
        'correct_answer': correctAnswer?.trim(),
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'section_id': row[1],
      'question_number': row[2],
      'question_text': row[3],
      'points': row[4].toString(),
      'choices': row[5],
      'correct_answer': row[6],
      'created_at': row[7].toString(),
    };
  }
}
