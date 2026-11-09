import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class QuestionService {
  static Future<List<Map<String, dynamic>>> getBySection(
    int sectionId,
  ) async {
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
        'points': row[4].toString(),
        'choices': row[5],
        'correct_answer': normalizedCorrect,
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
    if (questionNumber < 1) {
      throw Exception(
        'Question number must be at least 1.',
      );
    }

    if (questionText.trim().isEmpty) {
      throw Exception(
        'Question text is required.',
      );
    }

    if (points < 0) {
      throw Exception(
        'Question points cannot be negative.',
      );
    }

    return Database.pool.runTx<Map<String, dynamic>>((tx) async {
      final secRows = await tx.execute(
        Sql.named('''
          SELECT question_type
          FROM exam_sections
          WHERE id = @section_id
        '''),
        parameters: {'section_id': sectionId},
      );
      final qType = secRows.isNotEmpty
          ? (secRows.first[0]?.toString().trim().toLowerCase() ?? '')
          : '';

      String? normalizedAnswer = (correctAnswer?.trim().isEmpty ?? true)
          ? null
          : correctAnswer!.trim();
      if (normalizedAnswer != null && qType == 'identification') {
        normalizedAnswer = normalizedAnswer.toUpperCase();
      }

      // Ensure question_number does not collide if an out-of-sync number is sent
      var effectiveNumber = questionNumber;
      final existingNum = await tx.execute(
        Sql.named('''
          SELECT 1 FROM questions
          WHERE section_id = @section_id AND question_number = @question_number
        '''),
        parameters: {
          'section_id': sectionId,
          'question_number': effectiveNumber,
        },
      );
      if (existingNum.isNotEmpty) {
        final maxRows = await tx.execute(
          Sql.named('''
            SELECT COALESCE(MAX(question_number), 0)::int + 1
            FROM questions
            WHERE section_id = @section_id
          '''),
          parameters: {'section_id': sectionId},
        );
        effectiveNumber = maxRows.first[0]! as int;
      }

      final result = await tx.execute(
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
          'question_number': effectiveNumber,
          'question_text': questionText.trim(),
          'points': points,
          'choices': choices == null ? null : jsonEncode(choices),
          'correct_answer': normalizedAnswer,
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
    });
  }

  static Future<bool> deleteDraftQuestion(
    int id, {
    required int userId,
    required String role,
  }) async {
    return Database.pool.runTx<bool>((tx) async {
      final result = await tx.execute(
        Sql.named('''
          DELETE FROM questions AS q
          USING exam_sections AS s, exams AS e, classes AS c
          WHERE q.id = @id AND s.id = q.section_id AND e.id = s.exam_id AND c.id = e.class_id
            AND (@role = 'admin' OR (@role = 'teacher' AND c.teacher_id = @user_id))
            AND NOT EXISTS (SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id)
          RETURNING q.id, q.section_id, q.question_number
        '''),
        parameters: {'id': id, 'user_id': userId, 'role': role},
      );

      if (result.isEmpty) return false;

      final deletedSectionId = result.first[1]! as int;
      final deletedQuestionNumber = result.first[2]! as int;

      // Re-sequence remaining questions in the section so question_number stays 1..N
      await tx.execute(
        Sql.named('''
          UPDATE questions
          SET question_number = question_number - 1
          WHERE section_id = @section_id AND question_number > @deleted_number
        '''),
        parameters: {
          'section_id': deletedSectionId,
          'deleted_number': deletedQuestionNumber,
        },
      );

      return true;
    });
  }

  /// Edits a question's text, points, choices, correct answer, and optionally
  /// reassigns it to another section ([targetSectionId]) within the same draft
  /// exam while strictly preserving its `question_number` within its section.
  static Future<Map<String, dynamic>?> updateDraftQuestion(
    int id, {
    required int userId,
    required String role,
    required String questionText,
    required num points,
    dynamic choices,
    String? correctAnswer,
    int? targetSectionId,
  }) async {
    if (questionText.trim().isEmpty) {
      throw Exception('Question text is required.');
    }

    if (points < 0) {
      throw Exception('Question points cannot be negative.');
    }

    return Database.pool.runTx<Map<String, dynamic>?>((tx) async {
      final currentRows = await tx.execute(
        Sql.named('''
          SELECT q.section_id, q.question_number, s.exam_id, s.question_type
          FROM questions q
          JOIN exam_sections s ON s.id = q.section_id
          JOIN exams e ON e.id = s.exam_id
          JOIN classes c ON c.id = e.class_id
          WHERE q.id = @id
            AND (@role = 'admin' OR (@role = 'teacher' AND c.teacher_id = @user_id))
            AND NOT EXISTS (SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id)
          FOR UPDATE OF q
        '''),
        parameters: {'id': id, 'user_id': userId, 'role': role},
      );

      if (currentRows.isEmpty) return null;

      final currentSectionId = currentRows.first[0]! as int;
      final currentQuestionNumber = currentRows.first[1]! as int;
      final examId = currentRows.first[2]! as int;
      var effectiveType =
          currentRows.first[3]?.toString().trim().toLowerCase() ?? '';

      var newSectionId = currentSectionId;
      var newQuestionNumber = currentQuestionNumber;

      if (targetSectionId != null && targetSectionId != currentSectionId) {
        final targetSec = await tx.execute(
          Sql.named('''
            SELECT id, question_type FROM exam_sections
            WHERE id = @sec_id AND exam_id = @exam_id
          '''),
          parameters: {'sec_id': targetSectionId, 'exam_id': examId},
        );
        if (targetSec.isEmpty) {
          throw Exception('Target section does not belong to this exam.');
        }
        effectiveType =
            targetSec.first[1]?.toString().trim().toLowerCase() ?? effectiveType;

        final maxNoRows = await tx.execute(
          Sql.named('''
            SELECT COALESCE(MAX(question_number), 0)::int + 1
            FROM questions
            WHERE section_id = @sec_id
          '''),
          parameters: {'sec_id': targetSectionId},
        );
        newSectionId = targetSectionId;
        newQuestionNumber = maxNoRows.first[0]! as int;
      }

      String? normalizedAnswer = (correctAnswer?.trim().isEmpty ?? true)
          ? null
          : correctAnswer!.trim();
      if (normalizedAnswer != null && effectiveType == 'identification') {
        normalizedAnswer = normalizedAnswer.toUpperCase();
      }

      final result = await tx.execute(
        Sql.named('''
          UPDATE questions
          SET
            section_id = @section_id,
            question_number = @question_number,
            question_text = @question_text,
            points = @points,
            choices = @choices,
            correct_answer = @correct_answer
          WHERE id = @id
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
          'id': id,
          'section_id': newSectionId,
          'question_number': newQuestionNumber,
          'question_text': questionText.trim(),
          'points': points,
          'choices': choices == null ? null : jsonEncode(choices),
          'correct_answer': normalizedAnswer,
        },
      );

      if (result.isEmpty) return null;

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
    });
  }
}
