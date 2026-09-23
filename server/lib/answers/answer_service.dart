import 'package:postgres/postgres.dart';

import '../database.dart';

class AnswerService {
  static Future<Map<String, dynamic>> submit({
    required int attemptId,
    required int questionId,
    required String rawAnswer,
  }) async {
    final questionResult = await Database.pool.execute(
      Sql.named('''
        SELECT
          q.id,
          q.question_text,
          q.points,
          q.correct_answer,
          es.exam_id
        FROM questions q
        JOIN exam_sections es ON es.id = q.section_id
        JOIN exam_attempts ea ON ea.exam_id = es.exam_id
        WHERE q.id = @question_id
          AND ea.id = @attempt_id
      '''),
      parameters: {
        'question_id': questionId,
        'attempt_id': attemptId,
      },
    );

    if (questionResult.isEmpty) {
      throw Exception('Question does not belong to this attempt');
    }

    final question = questionResult.first;

    final correctAnswer = question[3]?.toString().trim();
    final answer = rawAnswer.trim();

    final isCorrect = correctAnswer != null &&
        answer.toLowerCase() == correctAnswer.toLowerCase();

    final points = question[2];
    final pointsEarned = isCorrect ? points : 0;

    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO student_answers (
          attempt_id,
          question_id,
          raw_answer,
          recognized_answer,
          points_earned,
          is_correct,
          confidence,
          verification_status
        )
        VALUES (
          @attempt_id,
          @question_id,
          @raw_answer,
          @recognized_answer,
          @points_earned,
          @is_correct,
          1.0,
          'automatic'
        )
        ON CONFLICT (attempt_id, question_id)
        DO UPDATE SET
          raw_answer = EXCLUDED.raw_answer,
          recognized_answer = EXCLUDED.recognized_answer,
          points_earned = EXCLUDED.points_earned,
          is_correct = EXCLUDED.is_correct,
          confidence = EXCLUDED.confidence,
          verification_status = EXCLUDED.verification_status
        RETURNING
          id,
          attempt_id,
          question_id,
          raw_answer,
          recognized_answer,
          points_earned,
          is_correct,
          confidence,
          verification_status,
          created_at
      '''),
      parameters: {
        'attempt_id': attemptId,
        'question_id': questionId,
        'raw_answer': answer,
        'recognized_answer': answer,
        'points_earned': pointsEarned,
        'is_correct': isCorrect,
      },
    );

    await Database.pool.execute(
      Sql.named('''
        UPDATE exam_attempts
        SET score = (
          SELECT COALESCE(SUM(points_earned), 0)
          FROM student_answers
          WHERE attempt_id = @attempt_id
        )
        WHERE id = @attempt_id
      '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'attempt_id': row[1],
      'question_id': row[2],
      'raw_answer': row[3],
      'recognized_answer': row[4],
      'points_earned': row[5].toString(),
      'is_correct': row[6],
      'confidence': row[7]?.toString(),
      'verification_status': row[8],
      'created_at': row[9].toString(),
    };
  }

  static Future<Map<String, dynamic>?> verify({
    required int attemptId,
    required int answerId,
    required bool isCorrect,
    required num pointsEarned,
    String? recognizedAnswer,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
        UPDATE student_answers sa
        SET
          is_correct = @is_correct,
          points_earned = @points_earned,
          recognized_answer = COALESCE(
            @recognized_answer,
            sa.recognized_answer
          ),
          verification_status = 'verified'
        FROM questions q
        JOIN exam_sections es ON es.id = q.section_id
        JOIN exam_attempts ea ON ea.exam_id = es.exam_id
        WHERE sa.id = @answer_id
          AND sa.attempt_id = @attempt_id
          AND sa.question_id = q.id
          AND ea.id = sa.attempt_id
          AND ea.status = 'processing'
          AND @points_earned >= 0
          AND @points_earned <= q.points
        RETURNING
          sa.id,
          sa.attempt_id,
          sa.question_id,
          sa.raw_answer,
          sa.recognized_answer,
          sa.points_earned,
          sa.is_correct,
          sa.confidence,
          sa.verification_status,
          sa.created_at
      '''),
      parameters: {
        'answer_id': answerId,
        'attempt_id': attemptId,
        'is_correct': isCorrect,
        'points_earned': pointsEarned,
        'recognized_answer': recognizedAnswer,
      },
    );

    if (result.isEmpty) {
      return null;
    }

    await Database.pool.execute(
      Sql.named('''
        UPDATE exam_attempts
        SET score = (
          SELECT COALESCE(SUM(points_earned), 0)
          FROM student_answers
          WHERE attempt_id = @attempt_id
        )
        WHERE id = @attempt_id
      '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'attempt_id': row[1],
      'question_id': row[2],
      'raw_answer': row[3],
      'recognized_answer': row[4],
      'points_earned': row[5].toString(),
      'is_correct': row[6],
      'confidence': row[7]?.toString(),
      'verification_status': row[8],
      'created_at': row[9].toString(),
    };
  }
}
