import 'package:postgres/postgres.dart';

import '../database.dart';

class AcceptableAnswerService {
  static Future<List<Map<String, dynamic>>> getByQuestion(
    int questionId,
  ) async {
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT
          id,
          question_id,
          answer,
          created_at
        FROM acceptable_answers
        WHERE question_id = @question_id
        ORDER BY id
      '''),
      parameters: {
        'question_id': questionId,
      },
    );

    return result.map((row) {
      return {
        'id': row[0],
        'question_id': row[1],
        'answer': row[2],
        'created_at': row[3].toString(),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int questionId,
    required String answer,
  }) async {
    if (answer.trim().isEmpty) {
      throw Exception(
        'Answer is required.',
      );
    }

    final result = await Database.pool.execute(
      Sql.named('''
        INSERT INTO acceptable_answers (
          question_id,
          answer
        )
        VALUES (
          @question_id,
          @answer
        )
        RETURNING
          id,
          question_id,
          answer,
          created_at
      '''),
      parameters: {
        'question_id': questionId,
        'answer': answer.trim(),
      },
    );

    final row = result.first;

    return {
      'id': row[0],
      'question_id': row[1],
      'answer': row[2],
      'created_at': row[3].toString(),
    };
  }
}