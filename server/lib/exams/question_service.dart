import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'package:server/database.dart';
import 'package:server/questions/question_service.dart' as questions;

class QuestionService {
  static Future<List<Map<String, dynamic>>> getAll({
    required int sectionId,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          q.id,
          q.section_id,
          q.question_number,
          q.question_text,
          q.points,
          q.choices,
          q.correct_answer,
          q.created_at,
          s.question_type
        FROM questions q
        JOIN exam_sections s ON s.id = q.section_id
        WHERE q.section_id = @section_id
        ORDER BY q.question_number ASC, q.id ASC
      '''),
      parameters: {
        'section_id': sectionId,
      },
    );

    return result.map((row) {
      final qType = row[8]?.toString() ?? '';
      final rawCorrect = row[6]?.toString();
      final normalizedCorrect =
          (rawCorrect != null && qType == 'identification')
              ? rawCorrect.trim().toUpperCase()
              : rawCorrect;
      return {
        'id': row[0],
        'section_id': row[1],
        'question_number': row[2],
        'question_text': row[3],
        'points': row[4],
        'choices': row[5],
        'correct_answer': normalizedCorrect,
        'created_at': row[7].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int sectionId,
    required int questionNumber,
    int? examId,
    required String questionText,
    required num points,
    dynamic choices,
    String? correctAnswer,
  }) async {
    final choicesJson = choices == null ? null : jsonEncode(choices);

    final secRows = await Database.pool.execute(
      Sql.named('''
        SELECT s.question_type, e.creation_mode
        FROM exam_sections s
        JOIN exams e ON e.id = s.exam_id
        WHERE s.id = @section_id AND (@exam_id::bigint IS NULL OR e.id = @exam_id)
      '''),
      parameters: {'section_id': sectionId, 'exam_id': examId},
    );
    if (secRows.isEmpty) {
      throw ArgumentError('Section does not belong to this exam.');
    }
    if (secRows.first[1] == 'answer_key') {
      return questions.QuestionService.create(
        sectionId: sectionId,
        questionNumber: questionNumber,
        questionText: questionText,
        points: points,
        choices: choices,
        correctAnswer: correctAnswer,
      );
    }
    if (questionText.trim().isEmpty) {
      throw ArgumentError('Question text is required.');
    }
    final qType = secRows.first[0]?.toString().trim().toLowerCase() ?? '';

    var normalizedAnswer = correctAnswer?.trim();
    if (normalizedAnswer != null &&
        normalizedAnswer.isNotEmpty &&
        qType == 'identification') {
      normalizedAnswer = normalizedAnswer.toUpperCase();
    }

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
          CAST(@choices AS jsonb),
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
        'choices': choicesJson,
        'correct_answer': normalizedAnswer,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'section_id': row[1],
      'question_number': row[2],
      'question_text': row[3],
      'points': row[4],
      'choices': row[5],
      'correct_answer': row[6],
      'created_at': row[7].toString(),
    };
  }
}
