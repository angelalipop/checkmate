import 'package:postgres/postgres.dart';

import 'package:server/database.dart';
import 'package:server/exams/exam_validator.dart';

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
          u.name AS teacher_name,
          e.assessment_type,
          e.version,
          c.school_year,
          c.semester,
          c.year_level,
          (
            SELECT string_agg(q.cid::text, ',' ORDER BY q.cid)
            FROM (
              SELECT x.class_id AS cid
              FROM exam_class_assignments x
              WHERE x.exam_id = e.id
              UNION
              SELECT e.class_id
            ) q
          ) AS class_ids, e.grading_period, e.creation_mode, e.manual_max_score
        FROM exams e
        JOIN classes c ON c.id = e.class_id
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN users u ON u.id = c.teacher_id
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
    final classIds = (exam[18]?.toString() ?? '')
        .split(',')
        .map(int.tryParse)
        .whereType<int>()
        .toList();

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
      final sectionId = section[0]! as int;

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
        'question_count': questions.length,
        'questions': questions,
      });
    }

    // Retrieve all students assigned to this assessment across all assigned
    // sections (classes).
    final studentRows = await Database.pool.execute(
      Sql.named('''
        SELECT
          st.id,
          st.class_id,
          st.student_number,
          st.first_name,
          st.last_name,
          st.email,
          c.section
        FROM students st
        JOIN classes c ON c.id = st.class_id
        WHERE st.class_id = ANY(@class_ids)
        ORDER BY LOWER(c.section), LOWER(st.last_name), LOWER(st.first_name), st.student_number, st.id
      '''),
      parameters: {
        'class_ids': TypedValue(
          Type.bigIntegerArray,
          classIds.isEmpty ? <int>[exam[1]! as int] : classIds,
        ),
      },
    );

    final students = studentRows.map((s) {
      return {
        'id': s[0],
        'class_id': s[1],
        'student_number': s[2],
        'first_name': s[3],
        'last_name': s[4],
        'email': s[5],
        'section': s[6],
        'class': {
          'id': s[1],
          'section': s[6],
        },
      };
    }).toList();

    final validation = ExamValidator.validate(
      assessmentType: exam[13]?.toString(),
      title: exam[2]?.toString(),
      description: exam[3]?.toString(),
      sections: sections,
    );

    return {
      'id': exam[0],
      'class_id': exam[1],
      'title': exam[2],
      'description': exam[3],
      'instructions': exam[4],
      'status': exam[5],
      'created_at': exam[6].toString(),
      'updated_at': exam[7].toString(),
      'assessment_type': exam[13],
      'version': exam[14],
      'school_year': exam[15],
      'semester': exam[16],
      'year_level': exam[17],
      'class_ids': classIds,
      'grading_period': exam[19],
      'creation_mode': exam[20],
      'manual_max_score': exam[21] == null ? null : num.parse('${exam[21]}'),
      'class': {
        'id': exam[1],
        'section': exam[8],
        'school_year': exam[15],
        'semester': exam[16],
        'year_level': exam[17],
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
      'students': students,
      'validation': validation.toJson(),
    };
  }
}
