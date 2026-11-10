import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class AttemptService {
  static double _toDouble(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

  static String _normalizeAnswerForComparison(
    String raw,
    String questionType,
  ) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final upper = trimmed.toUpperCase();
    if (upper == 'UNANSWERED' ||
        upper == 'AMBIGUOUS' ||
        upper == 'MULTIPLE' ||
        upper == 'OCR PENDING' ||
        upper == 'BLANK') {
      return '';
    }
    final type = questionType.trim().toLowerCase();
    if (type == 'true_false' || type == 'true or false' || type == 'tf') {
      if (upper == 'T' || upper == 'TRUE') return 'T';
      if (upper == 'F' || upper == 'FALSE') return 'F';
      return upper;
    }
    if (type == 'multiple_choice' ||
        type == 'multiple choice' ||
        type == 'mc' ||
        type == 'mcq') {
      return upper;
    }
    // Identification: compare in uppercase with collapsed whitespace.
    return upper.replaceAll(RegExp(r'\s+'), ' ');
  }

  static Future<Map<String, dynamic>> create({
    required int examId,
    required int studentId,
  }) async {
    final eligibility = await Database.pool.execute(
      Sql.named('''
        SELECT e.id
        FROM exams e
        JOIN students s ON (
          s.class_id = e.class_id
          OR s.class_id IN (
            SELECT x.class_id FROM exam_class_assignments x
            WHERE x.exam_id = e.id
          )
        )
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

  /// Upserts a verified answer sheet scan for `(examId, studentId)` in a single
  /// transaction, grades all submitted answers against `questions` and
  /// `acceptable_answers`, updates `exam_attempts` to `'completed'`, removes
  /// any record in `assessment_absences`, and ensures `(exam_id, class_id)` is
  /// linked in `exam_class_assignments` so the scorebook updates immediately.
  static Future<Map<String, dynamic>> recordVerifiedScan({
    required int examId,
    required List<Map<String, dynamic>> answers, int? studentId,
    int? classId,
    String? studentNumber,
    String? sectionName,
    int? teacherId,
  }) async {
    return Database.pool.runTx((tx) async {
      // 1. Verify exam exists.
      final examRows = await tx.execute(
        Sql.named('''
          SELECT e.id, e.class_id, e.title, e.version, e.assessment_type,
                 s.code AS subject_code, s.name AS subject_name
          FROM exams e
          JOIN classes c ON c.id = e.class_id
          JOIN subjects s ON s.id = c.subject_id
          WHERE e.id = @exam_id
        '''),
        parameters: {'exam_id': examId},
      );

      if (examRows.isEmpty) {
        throw Exception('Exam not found.');
      }

      final examRow = examRows.first;
      final defaultClassId = examRow[1]! as int;
      final examTitle = examRow[2]?.toString() ?? 'Exam';
      final examVersion = (examRow[3] as int?) ?? 1;
      final assessmentType = examRow[4]?.toString();
      final subjectCode = examRow[5]?.toString() ?? '';
      final subjectName = examRow[6]?.toString() ?? '';

      // 2. Resolve the enrolled student record in the exam's assigned class(es).
      ResultRow? studentRow;

      if (studentId != null && studentId > 0) {
        final byId = await tx.execute(
          Sql.named('''
            SELECT st.id, st.class_id, st.student_number,
                   st.first_name, st.last_name, st.email, c.section
            FROM students st
            JOIN classes c ON c.id = st.class_id
            WHERE st.id = @student_id
              AND (
                st.class_id = @default_class_id
                OR st.class_id = COALESCE(@req_class_id, -1)
                OR st.class_id IN (
                  SELECT x.class_id FROM exam_class_assignments x
                  WHERE x.exam_id = @exam_id
                )
              )
            LIMIT 1
          '''),
          parameters: {
            'student_id': studentId,
            'default_class_id': defaultClassId,
            'req_class_id': classId,
            'exam_id': examId,
          },
        );
        if (byId.isNotEmpty) {
          studentRow = byId.first;
        }
      }

      if (studentRow == null &&
          studentNumber != null &&
          studentNumber.trim().isNotEmpty) {
        final cleanNum = studentNumber.trim();
        final cleanSec = (sectionName ?? '').trim();
        final byNumber = await tx.execute(
          Sql.named('''
            SELECT st.id, st.class_id, st.student_number,
                   st.first_name, st.last_name, st.email, c.section
            FROM students st
            JOIN classes c ON c.id = st.class_id
            WHERE LOWER(BTRIM(st.student_number)) = LOWER(BTRIM(@student_number))
              AND (
                st.class_id = @default_class_id
                OR st.class_id = COALESCE(@req_class_id, -1)
                OR st.class_id IN (
                  SELECT x.class_id FROM exam_class_assignments x
                  WHERE x.exam_id = @exam_id
                )
              )
            ORDER BY
              (st.class_id = COALESCE(@req_class_id, -1)) DESC,
              (LOWER(BTRIM(c.section)) = LOWER(BTRIM(@section_name))) DESC,
              st.id ASC
            LIMIT 1
          '''),
          parameters: {
            'student_number': cleanNum,
            'default_class_id': defaultClassId,
            'req_class_id': classId,
            'exam_id': examId,
            'section_name': cleanSec,
          },
        );
        if (byNumber.isNotEmpty) {
          studentRow = byNumber.first;
        }
      }

      if (studentRow == null) {
        throw Exception(
          'Selected student could not be found in the enrolled section for this exam.',
        );
      }

      final resolvedStudentId = studentRow[0]! as int;
      final resolvedClassId = studentRow[1]! as int;
      final resolvedStudentNumber = studentRow[2]?.toString() ?? '';
      final resolvedFirstName = studentRow[3]?.toString() ?? '';
      final resolvedLastName = studentRow[4]?.toString() ?? '';
      final resolvedEmail = studentRow[5]?.toString();
      final resolvedSection = studentRow[6]?.toString() ?? '';

      // Ensure the exam is assigned to this student's class in exam_class_assignments
      // so the scorebook for this section always includes the assessment.
      await tx.execute(
        Sql.named('''
          INSERT INTO exam_class_assignments
            (exam_id, class_id, exam_version, assigned_by)
          VALUES (@exam_id, @class_id, @version, @teacher_id)
          ON CONFLICT (exam_id, class_id) DO NOTHING
        '''),
        parameters: {
          'exam_id': examId,
          'class_id': resolvedClassId,
          'version': examVersion,
          'teacher_id': teacherId,
        },
      );

      // 3. Load all questions and acceptable answers for this exam.
      final questionRows = await tx.execute(
        Sql.named('''
          SELECT q.id, q.section_id, q.question_number, q.points,
                 q.correct_answer, es.name AS section_name,
                 es.question_type, es.section_order
          FROM questions q
          JOIN exam_sections es ON es.id = q.section_id
          WHERE es.exam_id = @exam_id
          ORDER BY es.section_order ASC, es.id ASC, q.question_number ASC, q.id ASC
        '''),
        parameters: {'exam_id': examId},
      );

      final acceptableRows = await tx.execute(
        Sql.named('''
          SELECT aa.question_id, aa.answer
          FROM acceptable_answers aa
          JOIN questions q ON q.id = aa.question_id
          JOIN exam_sections es ON es.id = q.section_id
          WHERE es.exam_id = @exam_id
        '''),
        parameters: {'exam_id': examId},
      );

      final acceptableByQuestion = <int, Set<String>>{};
      for (final r in acceptableRows) {
        final qid = r[0]! as int;
        final ans = (r[1]?.toString() ?? '')
            .trim()
            .toUpperCase()
            .replaceAll(RegExp(r'\s+'), ' ');
        if (ans.isNotEmpty) {
          acceptableByQuestion.putIfAbsent(qid, () => <String>{}).add(ans);
        }
      }

      double maxScore = 0;
      for (final q in questionRows) {
        maxScore += _toDouble(q[3]);
      }

      // 4. Upsert exam_attempts row for (exam_id, student_id) — or any existing
      // attempt row for the same student_number in this class on this exam.
      final existingAttempts = await tx.execute(
        Sql.named('''
          SELECT a.id
          FROM exam_attempts a
          JOIN students st ON st.id = a.student_id
          WHERE a.exam_id = @exam_id
            AND (
              a.student_id = @student_id
              OR (
                st.class_id = @class_id
                AND LOWER(BTRIM(st.student_number)) = LOWER(BTRIM(@student_number))
              )
            )
          ORDER BY COALESCE(a.completed_at, a.created_at) DESC, a.id DESC
        '''),
        parameters: {
          'exam_id': examId,
          'student_id': resolvedStudentId,
          'class_id': resolvedClassId,
          'student_number': resolvedStudentNumber,
        },
      );

      final updatedExisting = existingAttempts.isNotEmpty;
      late final int attemptId;

      if (updatedExisting) {
        attemptId = existingAttempts.first[0]! as int;
        // Remove any older duplicate attempts for the same student + exam.
        if (existingAttempts.length > 1) {
          final duplicateIds = existingAttempts
              .skip(1)
              .map((r) => r[0]! as int)
              .toList();
          await tx.execute(
            Sql.named('''
              DELETE FROM exam_attempts
              WHERE id = ANY(@dup_ids)
            '''),
            parameters: {
              'dup_ids': TypedValue(Type.bigIntegerArray, duplicateIds),
            },
          );
        }
        await tx.execute(
          Sql.named('''
            UPDATE exam_attempts
            SET student_id = @student_id,
                max_score = @max_score,
                status = 'processing'
            WHERE id = @attempt_id
          '''),
          parameters: {
            'attempt_id': attemptId,
            'student_id': resolvedStudentId,
            'max_score': maxScore,
          },
        );
        await tx.execute(
          Sql.named('DELETE FROM student_answers WHERE attempt_id = @attempt_id'),
          parameters: {'attempt_id': attemptId},
        );
      } else {
        final inserted = await tx.execute(
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
            RETURNING id
          '''),
          parameters: {
            'exam_id': examId,
            'student_id': resolvedStudentId,
            'max_score': maxScore,
          },
        );
        attemptId = inserted.first[0]! as int;
      }

      // Index submitted answers by question_id or by (section_id/section_index, question_number).
      final submittedByQuestionId = <int, Map<String, dynamic>>{};
      final submittedBySectionAndNum = <String, Map<String, dynamic>>{};

      for (final raw in answers) {
        final qid = int.tryParse('${raw['question_id'] ?? ''}');
        if (qid != null && qid > 0) {
          submittedByQuestionId[qid] = raw;
        }
        final secId = int.tryParse('${raw['section_id'] ?? ''}');
        final secOrder = int.tryParse('${raw['section_index'] ?? ''}');
        final qNum = int.tryParse('${raw['question_number'] ?? ''}');
        if (qNum != null) {
          if (secId != null) {
            submittedBySectionAndNum['id:$secId:$qNum'] = raw;
          }
          if (secOrder != null) {
            submittedBySectionAndNum['idx:$secOrder:$qNum'] = raw;
          }
          submittedBySectionAndNum['num:$qNum'] = raw;
        }
      }

      // Map section order index (0..N-1) for fallback lookup.
      final distinctSectionIds = <int>[];
      for (final q in questionRows) {
        final sid = q[1]! as int;
        if (!distinctSectionIds.contains(sid)) {
          distinctSectionIds.add(sid);
        }
      }

      double totalEarnedScore = 0;
      final sectionStats = <int, Map<String, dynamic>>{};
      final savedAnswers = <Map<String, dynamic>>[];

      for (final q in questionRows) {
        final qId = q[0]! as int;
        final secId = q[1]! as int;
        final qNum = q[2]! as int;
        final points = _toDouble(q[3]);
        final correctRaw = q[4]?.toString() ?? '';
        final secName = q[5]?.toString() ?? 'Section';
        final secType = q[6]?.toString() ?? 'multiple_choice';
        final secIndex = distinctSectionIds.indexOf(secId);

        final submitted = submittedByQuestionId[qId] ??
            submittedBySectionAndNum['id:$secId:$qNum'] ??
            submittedBySectionAndNum['idx:$secIndex:$qNum'] ??
            submittedBySectionAndNum['num:$qNum'];

        final rawAnswerText =
            (submitted?['answer'] ?? submitted?['raw_answer'] ?? 'Unanswered')
                .toString()
                .trim();
        final confidenceRaw = _toDouble(submitted?['confidence'] ?? 1.0);
        final confidence = confidenceRaw.clamp(0.0, 1.0);

        final normalizedStudent = _normalizeAnswerForComparison(
          rawAnswerText,
          secType,
        );
        final normalizedCorrect = _normalizeAnswerForComparison(
          correctRaw,
          secType,
        );

        var isCorrect = false;
        if (normalizedStudent.isNotEmpty) {
          if (normalizedCorrect.isNotEmpty &&
              normalizedStudent == normalizedCorrect) {
            isCorrect = true;
          } else if (secType.toLowerCase() == 'identification') {
            final alts = acceptableByQuestion[qId];
            if (alts != null && alts.contains(normalizedStudent)) {
              isCorrect = true;
            }
          }
        }

        final earned = isCorrect ? points : 0.0;
        totalEarnedScore += earned;

        final storedAnswer = normalizedStudent.isEmpty
            ? 'Unanswered'
            : (secType.toLowerCase() == 'identification'
                ? normalizedStudent
                : rawAnswerText.toUpperCase());

        final insertedAns = await tx.execute(
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
              @confidence,
              'verified'
            )
            ON CONFLICT (attempt_id, question_id)
            DO UPDATE SET
              raw_answer = EXCLUDED.raw_answer,
              recognized_answer = EXCLUDED.recognized_answer,
              points_earned = EXCLUDED.points_earned,
              is_correct = EXCLUDED.is_correct,
              confidence = EXCLUDED.confidence,
              verification_status = 'verified'
            RETURNING id
          '''),
          parameters: {
            'attempt_id': attemptId,
            'question_id': qId,
            'raw_answer': storedAnswer,
            'recognized_answer': storedAnswer,
            'points_earned': earned,
            'is_correct': isCorrect,
            'confidence': confidence,
          },
        );

        final stats = sectionStats.putIfAbsent(
          secId,
          () => <String, dynamic>{
            'section_id': secId,
            'section_name': secName,
            'section_type': secType,
            'question_count': 0,
            'correct_count': 0,
            'earned_points': 0.0,
            'total_points': 0.0,
          },
        );
        stats['question_count'] = (stats['question_count'] as int) + 1;
        if (isCorrect) {
          stats['correct_count'] = (stats['correct_count'] as int) + 1;
        }
        stats['earned_points'] =
            (stats['earned_points'] as double) + earned;
        stats['total_points'] =
            (stats['total_points'] as double) + points;

        savedAnswers.add({
          'id': insertedAns.first[0],
          'question_id': qId,
          'section_id': secId,
          'question_number': qNum,
          'student_answer': storedAnswer,
          'correct_answer': correctRaw,
          'points': points,
          'points_earned': earned,
          'is_correct': isCorrect,
          'confidence': confidence,
          'verification_status': 'verified',
        });
      }

      // 5. Complete the attempt and clear any absence mark for this student + exam.
      final finalized = await tx.execute(
        Sql.named('''
          UPDATE exam_attempts
          SET score = @score,
              max_score = @max_score,
              status = 'completed',
              completed_at = NOW()
          WHERE id = @attempt_id
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
          'score': totalEarnedScore,
          'max_score': maxScore,
        },
      );

      await tx.execute(
        Sql.named('''
          DELETE FROM assessment_absences
          WHERE exam_id = @exam_id AND student_id = @student_id
        '''),
        parameters: {
          'exam_id': examId,
          'student_id': resolvedStudentId,
        },
      );

      final percentage =
          maxScore > 0 ? (totalEarnedScore / maxScore) * 100.0 : 0.0;

      final baseAttempt = _attemptFromRow(finalized.first);
      return {
        ...baseAttempt,
        'attempt_id': attemptId,
        'class_id': resolvedClassId,
        'section': resolvedSection,
        'updated_existing': updatedExisting,
        'percentage': percentage,
        'exam': {
          'id': examId,
          'title': examTitle,
          'assessment_type': assessmentType,
          'subject_code': subjectCode,
          'subject_name': subjectName,
        },
        'student': {
          'id': resolvedStudentId,
          'class_id': resolvedClassId,
          'section': resolvedSection,
          'student_number': resolvedStudentNumber,
          'first_name': resolvedFirstName,
          'last_name': resolvedLastName,
          'email': resolvedEmail,
        },
        'section_breakdown': sectionStats.values.toList(),
        'answers': savedAnswers,
      };
    });
  }

  static Future<bool> deleteAttempt({
    required int attemptId,
  }) async {
    final deleted = await Database.pool.execute(
      Sql.named('''
        DELETE FROM exam_attempts
        WHERE id = @attempt_id
        RETURNING id
      '''),
      parameters: {'attempt_id': attemptId},
    );
    return deleted.isNotEmpty;
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
          s.email,
          s.class_id,
          c.section
        FROM exam_attempts a
        JOIN exams e ON e.id = a.exam_id
        JOIN students s ON s.id = a.student_id
        LEFT JOIN classes c ON c.id = s.class_id
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
          sa.verification_status,
          es.id AS section_id,
          es.name AS section_name,
          es.question_type
        FROM student_answers sa
        JOIN questions q ON q.id = sa.question_id
        JOIN exam_sections es ON es.id = q.section_id
        WHERE sa.attempt_id = @attempt_id
        ORDER BY es.section_order ASC, q.question_number ASC
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
        'section_id': answer[11],
        'section_name': answer[12],
        'question_type': answer[13],
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
        'class_id': row[14],
        'section': row[15],
      },
      'answers': answers,
    };
  }

  /// When [teacherId] is given, only attempts on exams of that teacher's
  /// classes are returned (teacher accounts; admins pass null).
  static Future<List<Map<String, dynamic>>> list({
    int? examId,
    int? studentId,
    int? teacherId,
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

    if (teacherId != null) {
      conditions.add('''
        (
          c.teacher_id = @teacher_id
          OR sc.teacher_id = @teacher_id
          OR EXISTS (
            SELECT 1
            FROM exam_class_assignments x
            JOIN classes c2 ON c2.id = x.class_id
            WHERE x.exam_id = e.id
              AND c2.teacher_id = @teacher_id
          )
        )
      ''');
      parameters['teacher_id'] = teacherId;
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
          s.email,
          s.class_id,
          sc.section
        FROM exam_attempts a
        JOIN exams e ON e.id = a.exam_id
        JOIN students s ON s.id = a.student_id
        LEFT JOIN classes c ON c.id = e.class_id
        LEFT JOIN classes sc ON sc.id = s.class_id
        $whereClause
        ORDER BY COALESCE(a.completed_at, a.created_at) DESC, a.id DESC
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
          'class_id': row[14],
          'section': row[15],
        },
      };
    }).toList();
  }

  static Future<Map<String, dynamic>?> complete({
    required int attemptId,
  }) async {
    final attemptResult = await Database.pool.execute(
      Sql.named('''
        SELECT id, status, exam_id, student_id
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
    final examId = attemptResult.first[2]! as int;
    final studentId = attemptResult.first[3]! as int;

    if (status != 'processing') {
      throw Exception('Attempt is already completed');
    }

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

    final needsReview = (reviewResult.first[0]! as num) > 0;

    if (needsReview) {
      throw Exception('Attempt has answers that need review');
    }

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

    final unansweredCount = unansweredResult.first[0]! as num;

    if (unansweredCount > 0) {
      throw Exception('Attempt has unanswered questions');
    }

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

    await Database.pool.execute(
      Sql.named('''
        DELETE FROM assessment_absences
        WHERE exam_id = @exam_id AND student_id = @student_id
      '''),
      parameters: {
        'exam_id': examId,
        'student_id': studentId,
      },
    );

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
