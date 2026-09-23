import 'package:postgres/postgres.dart';

import '../database.dart';

class ExamService {
  static Future<List<Map<String, dynamic>>> getAll({
    int? classId,
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
        WHERE (@class_id::bigint IS NULL OR e.class_id = @class_id)
        ORDER BY e.id
      '''),
      parameters: {
        'class_id': classId,
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
        'description': description?.trim(),
        'instructions': instructions?.trim(),
        'status': status?.trim(),
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
}
