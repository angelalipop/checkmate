import 'package:postgres/postgres.dart';

import '../database.dart';

class AttemptService {
  static Future<Map<String, dynamic>> create({
    required int examId,
    required int studentId,
  }) async {
    final eligibility = await Database.pool.execute(
      Sql.named('''
 SELECT e.id
 FROM exams e
 JOIN students s ON s.class_id = e.class_id
 WHERE e.id = @exam_id
 AND s.id = @student_id
 '''),
      parameters: {
        'exam_id': examId,
        'student_id': studentId,
      },
    );

    if (eligibility.isEmpty) {
      throw Exception('Student is not enrolled in the exam class');
    }

    final maxScoreResult = await Database.pool.execute(
      Sql.named('''
 SELECT COALESCE(SUM(q.points), 0)
 FROM questions q
 JOIN exam_sections es ON es.id = q.section_id
 WHERE es.exam_id = @exam_id
 '''),
      parameters: {
        'exam_id': examId,
      },
    );

    final maxScore = maxScoreResult.first[0];

    final result = await Database.pool.execute(
      Sql.named('''
 INSERT INTO exam_attempts (
 exam_id,
 student_id,
 score,
 max_score,
 status,
 started_at
 )
 VALUES (
 @exam_id,
 @student_id,
 0,
 @max_score,
 'processing',
 NOW()
 )
 RETURNING
 id,
 exam_id,
 student_id,
 score,
 max_score,
 status,
 started_at,
 completed_at,
 created_at
 '''),
      parameters: {
        'exam_id': examId,
        'student_id': studentId,
        'max_score': maxScore,
      },
    );

    return _attemptFromRow(result.first);
  }

  static Future<Map<String, dynamic>?> getById({
    required int attemptId,
  }) async {
    final result = await Database.pool.execute(
      Sql.named('''
 SELECT
 a.id,
 a.exam_id,
 a.student_id,
 a.score,
 a.max_score,
 a.status,
 a.started_at,
 a.completed_at,
 a.created_at,
 e.title,
 s.student_number,
 s.first_name,
 s.last_name,
 s.email
 FROM exam_attempts a
 JOIN exams e ON e.id = a.exam_id
 JOIN students s ON s.id = a.student_id
 WHERE a.id = @attempt_id
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    if (result.isEmpty) {
      return null;
    }

    final row = result.first;

    final answersResult = await Database.pool.execute(
      Sql.named('''
 SELECT
 sa.id,
 sa.question_id,
 q.question_number,
 q.question_text,
 q.points,
 sa.raw_answer,
 sa.recognized_answer,
 sa.points_earned,
 sa.is_correct,
 sa.confidence,
 sa.verification_status
 FROM student_answers sa
 JOIN questions q ON q.id = sa.question_id
 WHERE sa.attempt_id = @attempt_id
 ORDER BY q.question_number
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    final answers = answersResult.map((answer) {
      return {
        'id': answer[0],
        'question_id': answer[1],
        'question_number': answer[2],
        'question_text': answer[3],
        'points': answer[4].toString(),
        'raw_answer': answer[5],
        'recognized_answer': answer[6],
        'points_earned': answer[7].toString(),
        'is_correct': answer[8],
        'confidence': answer[9]?.toString(),
        'verification_status': answer[10],
      };
    }).toList();

    return {
      'id': row[0],
      'exam_id': row[1],
      'student_id': row[2],
      'score': row[3].toString(),
      'max_score': row[4].toString(),
      'status': row[5],
      'started_at': row[6]?.toString(),
      'completed_at': row[7]?.toString(),
      'created_at': row[8].toString(),
      'exam': {
        'id': row[1],
        'title': row[9],
      },
      'student': {
        'id': row[2],
        'student_number': row[10],
        'first_name': row[11],
        'last_name': row[12],
        'email': row[13],
      },
      'answers': answers,
    };
  }

  static Future<List<Map<String, dynamic>>> list({
    int? examId,
    int? studentId,
  }) async {
    final conditions = <String>[];
    final parameters = <String, dynamic>{};

    if (examId != null) {
      conditions.add('a.exam_id = @exam_id');
      parameters['exam_id'] = examId;
    }

    if (studentId != null) {
      conditions.add('a.student_id = @student_id');
      parameters['student_id'] = studentId;
    }

    final whereClause = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')}';

    final result = await Database.pool.execute(
      Sql.named('''
 SELECT
 a.id,
 a.exam_id,
 a.student_id,
 a.score,
 a.max_score,
 a.status,
 a.started_at,
 a.completed_at,
 a.created_at,
 e.title,
 s.student_number,
 s.first_name,
 s.last_name,
 s.email
 FROM exam_attempts a
 JOIN exams e ON e.id = a.exam_id
 JOIN students s ON s.id = a.student_id
 $whereClause
 ORDER BY a.created_at DESC
 '''),
      parameters: parameters,
    );

    return result.map((row) {
      return {
        'id': row[0],
        'exam_id': row[1],
        'student_id': row[2],
        'score': row[3].toString(),
        'max_score': row[4].toString(),
        'status': row[5],
        'started_at': row[6]?.toString(),
        'completed_at': row[7]?.toString(),
        'created_at': row[8].toString(),
        'exam': {
          'id': row[1],
          'title': row[9],
        },
        'student': {
          'id': row[2],
          'student_number': row[10],
          'first_name': row[11],
          'last_name': row[12],
          'email': row[13],
        },
      };
    }).toList();
  }

  static Future<Map<String, dynamic>?> complete({
    required int attemptId,
  }) async {
    // Check that the attempt exists.
    final attemptResult = await Database.pool.execute(
      Sql.named('''
 SELECT id, status
 FROM exam_attempts
 WHERE id = @attempt_id
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    if (attemptResult.isEmpty) {
      throw Exception('Attempt not found');
    }

    final status = attemptResult.first[1]?.toString();

    // An attempt can only be completed once.
    if (status != 'processing') {
      throw Exception('Attempt is already completed');
    }

    // Do not allow completion while an answer still needs review.
    final reviewResult = await Database.pool.execute(
      Sql.named('''
 SELECT COUNT(*)
 FROM student_answers
 WHERE attempt_id = @attempt_id
 AND verification_status = 'needs_review'
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    final needsReview = (reviewResult.first[0] as num) > 0;

    if (needsReview) {
      throw Exception('Attempt has answers that need review');
    }

    // Make sure every question in the exam has an answer.
    final unansweredResult = await Database.pool.execute(
      Sql.named('''
 SELECT COUNT(*)
 FROM questions q
 JOIN exam_sections es ON es.id = q.section_id
 JOIN exam_attempts a ON a.exam_id = es.exam_id
 WHERE a.id = @attempt_id
 AND NOT EXISTS (
 SELECT 1
 FROM student_answers sa
 WHERE sa.attempt_id = a.id
 AND sa.question_id = q.id
 )
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    final unansweredCount = unansweredResult.first[0] as num;

    if (unansweredCount > 0) {
      throw Exception('Attempt has unanswered questions');
    }

    // Recalculate the score and complete the attempt.
    final result = await Database.pool.execute(
      Sql.named('''
 UPDATE exam_attempts
 SET
 score = (
 SELECT COALESCE(SUM(sa.points_earned), 0)
 FROM student_answers sa
 WHERE sa.attempt_id = @attempt_id
 ),
 status = 'completed',
 completed_at = NOW()
 WHERE id = @attempt_id
 AND status = 'processing'
 RETURNING
 id,
 exam_id,
 student_id,
 score,
 max_score,
 status,
 started_at,
 completed_at,
 created_at
 '''),
      parameters: {
        'attempt_id': attemptId,
      },
    );

    if (result.isEmpty) {
      return null;
    }

    return _attemptFromRow(result.first);
  }

  static Map<String, dynamic> _attemptFromRow(ResultRow row) {
    return {
      'id': row[0],
      'exam_id': row[1],
      'student_id': row[2],
      'score': row[3].toString(),
      'max_score': row[4].toString(),
      'status': row[5],
      'started_at': row[6]?.toString(),
      'completed_at': row[7]?.toString(),
      'created_at': row[8].toString(),
    };
  }
}
