import 'package:postgres/postgres.dart';

import 'package:server/database.dart';
import 'package:server/my_subjects/grading_calculator.dart';
import 'package:server/exams/exam_validator.dart';

/// An error whose [message] and optional [validation] details are safe to show
/// to the teacher (HTTP 400).
class ExamValidationException implements Exception {
  ExamValidationException(this.message, {this.validation});

  final String message;
  final ExamValidationResult? validation;

  Map<String, dynamic> toResponseBody() => <String, dynamic>{
        'status': 'error',
        'message': message,
        if (validation != null) ...<String, dynamic>{
          'errors': validation!.errors,
          'validation': validation!.toJson(),
        },
      };

  @override
  String toString() => message;
}

class ExamService {
  static const assessmentTypes = <String>{
    'quiz',
    'short_quiz',
    'long_quiz',
    'performance_task',
    'laboratory',
    'prelim',
    'midterm',
    'prefinal',
    'pre_finals',
    'final',
    'finals',
    'other',
  };

  static bool _constraintEnsured = false;

  static Future<void> _ensureAssessmentTypeConstraint() async {
    if (_constraintEnsured) return;
    _constraintEnsured = true;
    try {
      await Database.pool.execute('''
        ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_exams_assessment_type;
        ALTER TABLE exams
          ADD CONSTRAINT chk_exams_assessment_type CHECK (
            assessment_type IS NULL
            OR assessment_type IN (
              'quiz',
              'short_quiz',
              'long_quiz',
              'performance_task',
              'laboratory',
              'prelim',
              'midterm',
              'prefinal',
              'pre_finals',
              'final',
              'finals',
              'other'
            )
          );
      ''');
    } catch (_) {
      // Constraint already updated or managed externally.
    }
  }

  static List<int> _parseIds(Object? raw) {
    return (raw?.toString() ?? '')
        .split(',')
        .map(int.tryParse)
        .whereType<int>()
        .toList();
  }

  static List<String> _parseStrings(Object? raw) {
    return (raw?.toString() ?? '')
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Validates an exam's sections and questions in the database against the
  /// assessment type minimum requirements.
  static Future<ExamValidationResult> validateExamInDb(
    Session session,
    int examId, {
    required String? assessmentType,
    String? title,
    String? description,
  }) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT
          es.id,
          es.name,
          es.question_type,
          es.section_order,
          COUNT(q.id)::int AS question_count
        FROM exam_sections es
        LEFT JOIN questions q ON q.section_id = es.id
        WHERE es.exam_id = @exam_id
        GROUP BY es.id, es.name, es.question_type, es.section_order
        ORDER BY es.section_order, es.id
      '''),
      parameters: {'exam_id': examId},
    );

    final sections = rows
        .map(
          (r) => <String, dynamic>{
            'id': r[0],
            'name': r[1],
            'question_type': r[2],
            'section_order': r[3],
            'question_count': r[4],
          },
        )
        .toList();

    return ExamValidator.validate(
      assessmentType: assessmentType,
      title: title,
      description: description,
      sections: sections,
    );
  }

  /// When [teacherId] is given, only exams of that teacher's classes are
  /// returned (used for teacher accounts; admins pass null).
  static Future<List<Map<String, dynamic>>> getAll({
    int? classId,
    int? teacherId,
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
          s.code AS subject_code,
          e.assessment_type,
          e.version,
          (
            SELECT string_agg(q.cid::text, ',' ORDER BY q.cid)
            FROM (
              SELECT x.class_id AS cid
              FROM exam_class_assignments x
              WHERE x.exam_id = e.id
              UNION
              SELECT e.class_id
            ) q
          ) AS class_ids,
          c.school_year,
          c.semester,
          c.year_level,
          c.teacher_id,
          u.name AS teacher_name,
          (
            SELECT string_agg(c2.section, '|' ORDER BY c2.section)
            FROM (
              SELECT x.class_id AS cid
              FROM exam_class_assignments x
              WHERE x.exam_id = e.id
              UNION
              SELECT e.class_id
            ) q2
            JOIN classes c2 ON c2.id = q2.cid
          ) AS assigned_sections,
          s.id AS subject_id, e.grading_period, e.creation_mode, e.manual_max_score
        FROM exams e
        JOIN classes c ON c.id = e.class_id
        JOIN subjects s ON s.id = c.subject_id
        LEFT JOIN users u ON u.id = c.teacher_id
        WHERE (
          @class_id::bigint IS NULL
          OR e.class_id = @class_id
          OR EXISTS (
            SELECT 1 FROM exam_class_assignments x
            WHERE x.exam_id = e.id AND x.class_id = @class_id
          )
        )
        AND (
          @teacher_id::bigint IS NULL
          OR c.teacher_id = @teacher_id
        )
        ORDER BY e.created_at DESC
      '''),
      parameters: {
        'class_id': classId,
        'teacher_id': teacherId,
      },
    );

    return result.map((row) {
      final sectionsList = _parseStrings(row[19]);
      return {
        'id': row[0],
        'class_id': row[1],
        'title': row[2],
        'description': row[3],
        'instructions': row[4],
        'status': row[5],
        'created_at': row[6].toString(),
        'updated_at': row[7].toString(),
        'assessment_type': row[11],
        'grading_period': row[21],
        'creation_mode': row[22],
        'manual_max_score': row[23] == null ? null : num.parse('${row[23]}'),
        'version': row[12],
        // Every section (class) this exam is given to.
        'class_ids': _parseIds(row[13]),
        'school_year': row[14],
        'semester': row[15],
        'year_level': row[16],
        'sections': sectionsList,
        'class': {
          'id': row[1],
          'section': row[8],
          'school_year': row[14],
          'semester': row[15],
          'year_level': row[16],
          'subject': {
            'id': row[20],
            'name': row[9],
            'code': row[10],
          },
          if (row[17] != null)
            'teacher': {
              'id': row[17],
              'name': row[18],
            },
        },
      };
    }).toList();
  }

  static Future<Map<String, dynamic>> create({
    required int classId,
    required String title,
    List<int>? classIds,
    String? description,
    String? instructions,
    String? status,
    String? assessmentType,
    String? gradingPeriod,
    String creationMode = 'builder',
  }) async {
    if (creationMode != 'builder' && creationMode != 'answer_key') {
      throw ExamValidationException('Invalid exam creation mode.');
    }
    await _ensureAssessmentTypeConstraint();

    final normalizedStatus = status?.trim().toLowerCase();

    const allowedStatuses = {
      'draft',
      'published',
      'archived',
    };

    if (normalizedStatus != null &&
        !allowedStatuses.contains(normalizedStatus)) {
      throw ExamValidationException(
        'Invalid exam status. Use draft, published, or archived.',
      );
    }

    String? cleanType;
    if (assessmentType != null && assessmentType.trim().isNotEmpty) {
      if (!ExamValidator.isValidAssessmentType(assessmentType)) {
        throw ExamValidationException('Choose a valid assessment type.');
      }
      cleanType = ExamValidator.toDatabaseAssessmentType(assessmentType);
    }

    String? period;
    try { period = GradingCalculator.validatePeriod(gradingPeriod, cleanType); }
    on ArgumentError catch (e) { throw ExamValidationException(e.message.toString()); }

    if (normalizedStatus == 'published') {
      final validation = ExamValidator.validate(
        assessmentType: cleanType,
        title: title,
        description: description,
        sections: const <Map<String, dynamic>>[],
      );
      if (!validation.isValid) {
        throw ExamValidationException(
          validation.summaryMessage,
          validation: validation,
        );
      }
    }

    final targetClassIds = <int>{
      classId,
      if (classIds != null) ...classIds,
    }.toList()
      ..sort();

    return Database.pool.runTx<Map<String, dynamic>>((tx) async {
      final result = await tx.execute(
        Sql.named('''
          INSERT INTO exams (
            class_id,
            title,
            description,
            instructions,
            status,
            assessment_type, grading_period, creation_mode
          )
          VALUES (
            @class_id,
            @title,
            @description,
            @instructions,
            COALESCE(@status, 'draft'),
            @assessment_type, @grading_period, @creation_mode
          )
          RETURNING
            id,
            class_id,
            title,
            description,
            instructions,
            status,
            created_at,
            updated_at,
            assessment_type,
            version
        '''),
        parameters: {
          'class_id': classId,
          'title': title.trim(),
          'description':
              description?.trim().isEmpty ?? false ? null : description?.trim(),
          'instructions':
              instructions?.trim().isEmpty ?? false ? null : instructions?.trim(),
          'status': normalizedStatus,
          'assessment_type': cleanType,
          'grading_period': period,
          'creation_mode': creationMode,
        },
      );

      final row = result.first;
      final examId = row[0]! as int;

      for (final cid in targetClassIds) {
        await tx.execute(
          Sql.named('''
            INSERT INTO exam_class_assignments (exam_id, class_id, exam_version)
            VALUES (@exam_id, @class_id, @version)
            ON CONFLICT (exam_id, class_id) DO NOTHING
          '''),
          parameters: {
            'exam_id': examId,
            'class_id': cid,
            'version': row[9] ?? 1,
          },
        );
      }

      return {
        'id': row[0],
        'class_id': row[1],
        'title': row[2],
        'description': row[3],
        'instructions': row[4],
        'status': row[5],
        'created_at': row[6].toString(),
        'updated_at': row[7].toString(),
        'assessment_type': row[8],
        'version': row[9],
        'class_ids': targetClassIds,
        'grading_period': period,
        'creation_mode': creationMode,
      };
    });
  }

  /// Updates title / description / instructions / assessment type / status and,
  /// optionally, the sections (classes) the exam is given to.
  ///
  /// Returns null when the exam is not found or the user may not edit it.
  /// Throws [ExamValidationException] for bad input or when publishing an
  /// assessment that does not satisfy minimum question requirements.
  static Future<Map<String, dynamic>?> update(
    int id, {
    required int userId,
    required String role,
    required String title,
    String? description,
    String? instructions,
    int? classId,
    List<int>? classIds,
    String? assessmentType,
    String? status,
    String? gradingPeriod,
  }) async {
    await _ensureAssessmentTypeConstraint();

    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw ExamValidationException('Exam title is required.');
    }

    final typeText = assessmentType?.trim().toLowerCase();
    String? type;
    if (typeText != null && typeText.isNotEmpty) {
      if (!ExamValidator.isValidAssessmentType(typeText)) {
        throw ExamValidationException('Choose a valid assessment type.');
      }
      type = ExamValidator.toDatabaseAssessmentType(typeText);
    }

    final statusText = status?.trim().toLowerCase();
    final requestedStatus =
        (statusText == null || statusText.isEmpty) ? null : statusText;
    const allowedStatuses = {'draft', 'published', 'archived'};
    if (requestedStatus != null && !allowedStatuses.contains(requestedStatus)) {
      throw ExamValidationException(
        'Invalid exam status. Use draft, published, or archived.',
      );
    }

    final requested = classIds != null
        ? classIds.toSet()
        : (classId != null ? <int>{classId} : null);
    if (requested != null && requested.isEmpty) {
      throw ExamValidationException('Choose at least one section.');
    }
    if (requested != null && requested.length > 30) {
      throw ExamValidationException('Too many sections selected.');
    }

    String? clean(String? v) =>
        (v == null || v.trim().isEmpty) ? null : v.trim();

    return Database.pool.runTx<Map<String, dynamic>?>((tx) async {
      final found = await tx.execute(
        Sql.named('''
          SELECT e.class_id, e.status, c.teacher_id, c.subject_id,
                 EXISTS (
                   SELECT 1 FROM exam_attempts a WHERE a.exam_id = e.id
                 ),
                 e.assessment_type, e.grading_period, e.creation_mode
          FROM exams e
          JOIN classes c ON c.id = e.class_id
          WHERE e.id = @id
          FOR UPDATE OF e
        '''),
        parameters: {'id': id},
      );

      if (found.isEmpty) return null;

      final cur = found.first;
      final currentClassId = cur[0]! as int;
      final currentStatus = cur[1]! as String;
      final ownerId = cur[2] as int?;
      final currentAssessmentType = cur[5]?.toString();

      // Same rule as before: admins, or the teacher who owns the exam.
      if (role != 'admin' && ownerId != userId) return null;

      final assignedRows = await tx.execute(
        Sql.named(
          'SELECT class_id FROM exam_class_assignments WHERE exam_id = @id',
        ),
        parameters: {'id': id},
      );

      final current = <int>{
        currentClassId,
        for (final r in assignedRows) r[0]! as int,
      };

      var finalIds = current;
      var newPrimary = currentClassId;

      if (requested != null &&
          !(requested.length == current.length &&
              requested.containsAll(current))) {
        final rows = await tx.execute(
          Sql.named(
            'SELECT id, subject_id, teacher_id FROM classes '
            'WHERE id = ANY(@ids)',
          ),
          parameters: {
            'ids': TypedValue(Type.bigIntegerArray, requested.toList()),
          },
        );

        if (rows.length != requested.length) {
          throw ExamValidationException('Section not found.');
        }

        final distinctSubjects = <int>{};
        for (final r in rows) {
          distinctSubjects.add(r[1]! as int);
          if (role != 'admin' && r[2] != userId) {
            throw ExamValidationException(
              'You are not assigned to one of the selected sections.',
            );
          }
        }

        if (distinctSubjects.length > 1) {
          throw ExamValidationException(
            'An exam can only be given to sections of the same subject.',
          );
        }

        final sorted = requested.toList()..sort();
        newPrimary = (classId != null && requested.contains(classId))
            ? classId
            : (requested.contains(currentClassId)
                  ? currentClassId
                  : sorted.first);

        await tx.execute(
          Sql.named('''
            DELETE FROM exam_class_assignments
            WHERE exam_id = @id AND NOT (class_id = ANY(@ids))
          '''),
          parameters: {
            'id': id,
            'ids': TypedValue(Type.bigIntegerArray, sorted),
          },
        );

        for (final cid in sorted) {
          await tx.execute(
            Sql.named('''
              INSERT INTO exam_class_assignments
                (exam_id, class_id, exam_version, assigned_by)
              SELECT e.id, @class_id::bigint, e.version, @user_id::bigint
              FROM exams e
              WHERE e.id = @id
              ON CONFLICT (exam_id, class_id) DO NOTHING
            '''),
            parameters: {'id': id, 'class_id': cid, 'user_id': userId},
          );
        }

        finalIds = requested;
      }

      if (cur[7] == 'manual') throw ExamValidationException('Edit manual scores from the scorebook. Manual assessments cannot enter publishing.');
      final effectiveType = type ?? currentAssessmentType;
      String? period;
      try { period = GradingCalculator.validatePeriod(gradingPeriod ?? cur[6]?.toString(), effectiveType); }
      on ArgumentError catch(e) { throw ExamValidationException(e.message.toString()); }
      final effectiveStatus = requestedStatus ?? currentStatus;

      final validation = await validateExamInDb(
        tx,
        id,
        assessmentType: effectiveType,
        title: cleanTitle,
        description: clean(description),
      );

      // Strict minimum question validation is enforced when publishing or
      // submitting an assessment (or saving changes to a published assessment).
      // Incomplete assessments can always remain saved as drafts.
      if (effectiveStatus == 'published' && !validation.isValid) {
        throw ExamValidationException(
          validation.summaryMessage,
          validation: validation,
        );
      }

      final updated = await tx.execute(
        Sql.named('''
          UPDATE exams
          SET
            title = @title,
            description = @description,
            instructions = @instructions,
            class_id = @class_id,
            assessment_type = COALESCE(@type::text, assessment_type),
            status = COALESCE(@status::text, status),
            grading_period = @grading_period,
            updated_at = NOW()
          WHERE id = @id
          RETURNING
            id,
            class_id,
            title,
            description,
            instructions,
            status,
            created_at,
            updated_at,
            assessment_type,
            version
        '''),
        parameters: {
          'id': id,
          'title': cleanTitle,
          'description': clean(description),
          'instructions': clean(instructions),
          'class_id': newPrimary,
          'type': type,
          'status': requestedStatus,
          'grading_period': period,
        },
      );

      final row = updated.first;

      return {
        'id': row[0],
        'class_id': row[1],
        'title': row[2],
        'description': row[3],
        'instructions': row[4],
        'status': row[5],
        'created_at': row[6].toString(),
        'updated_at': row[7].toString(),
        'assessment_type': row[8],
        'version': row[9],
        'class_ids': (finalIds.toList()..sort()),
        'validation': validation.toJson(),
        'grading_period': period,
        'creation_mode': cur[7],
      };
    });
  }
}
