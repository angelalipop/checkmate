import 'package:postgres/postgres.dart';

import '../database.dart';

class ExamDetailService {
  static Future<Map<String, dynamic>?> getById(int examId) async {
    final examResult = await Database.pool.execute(
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
          s.code AS subject_code,
          c.teacher_id,
          u.name AS teacher_name
        FROM exams e
        JOIN classes c ON c.id = e.class_id
        JOIN subjects s ON s.id = c.subject_id
        JOIN users u ON u.id = c.teacher_id
        WHERE e.id = @exam_id
      '''),
      parameters: {
        'exam_id': examId,
      },
    );

    if (examResult.isEmpty) {
      return null;
    }

    final exam = examResult.first;

    final sectionResult = await Database.pool.execute(
      Sql.named('''
        SELECT
          id,
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

    final sections = <Map<String, dynamic>>[];

    for (final section in sectionResult) {
      final sectionId = section[0] as int;

      final questionResult = await Database.pool.execute(
        Sql.named('''
          SELECT
            id,
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

      final questions = questionResult.map((question) {
        return {
          'id': question[0],
          'question_number': question[1],
          'question_text': question[2],
          'points': question[3],
          'choices': question[4],
          'correct_answer': question[5],
          'created_at': question[6].toString(),
        };
      }).toList();

      sections.add({
        'id': section[0],
        'name': section[1],
        'question_type': section[2],
        'section_order': section[3],
        'default_points': section[4],
        'questions': questions,
      });
    }

    return {
      'id': exam[0],
      'class_id': exam[1],
      'title': exam[2],
      'description': exam[3],
      'instructions': exam[4],
      'status': exam[5],
      'created_at': exam[6].toString(),
      'updated_at': exam[7].toString(),
      'class': {
        'id': exam[1],
        'section': exam[8],
        'subject': {
          'name': exam[9],
          'code': exam[10],
        },
        'teacher': {
          'id': exam[11],
          'name': exam[12],
        },
      },
      'sections': sections,
    };
  }
}
