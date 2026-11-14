import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

import 'package:server/database.dart';
import 'package:server/my_subjects/my_subjects_service.dart';

/// Exception thrown when sending exam results fails.
class ResultEmailException implements Exception {
  /// Creates an email service exception.
  ResultEmailException(this.message, {this.statusCode = 400});

  /// The error message.
  final String message;

  /// The HTTP status code associated with the error.
  final int statusCode;

  @override
  String toString() => message;
}

/// Represents an HTTP error returned by Resend.
class ResendHttpException implements Exception {
  /// Creates a Resend HTTP exception.
  ResendHttpException(this.statusCode, this.message);

  /// The HTTP status code returned by Resend.
  final int statusCode;

  /// The error message returned by Resend.
  final String message;

  @override
  String toString() => message;
}

/// Handles sending finalized exam results through Resend.
class ResultEmailService {
  /// Sends finalized exam results to students in a class.
  static Future<Map<String, dynamic>> sendExamResults({
    required int actorId,
    required bool isAdmin,
    required int classId,
    required int examId,
  }) async {
    final apiKey = env['RESEND_API_KEY'] ?? '';
    final fromEmail = env['RESEND_FROM_EMAIL'] ?? '';

    if (apiKey.isEmpty || fromEmail.isEmpty) {
      throw ResultEmailException(
        'Email service is not configured. '
        'Check RESEND_API_KEY and RESEND_FROM_EMAIL.',
        statusCode: 500,
      );
    }

    // Test mode configuration.
    final testMode = env['RESEND_TEST_MODE']?.toLowerCase() == 'true';
    final testStudentId = int.tryParse(
      env['RESEND_TEST_STUDENT_ID'] ?? '',
    );
    final testRecipient = env['RESEND_TEST_TO_EMAIL']?.trim() ?? '';

    if (testMode && (testStudentId == null || testRecipient.isEmpty)) {
      throw ResultEmailException(
        'Test mode requires RESEND_TEST_STUDENT_ID '
        'and RESEND_TEST_TO_EMAIL.',
        statusCode: 500,
      );
    }

    // Find the class owner.
    final classRows = await Database.pool.execute(
      Sql.named('''
        SELECT teacher_id
        FROM classes
        WHERE id = @class_id
      '''),
      parameters: {'class_id': classId},
    );

    if (classRows.isEmpty) {
      throw ResultEmailException('Class not found.', statusCode: 404);
    }

    final ownerTeacherId = classRows.first[0] as int?;

    if (ownerTeacherId == null) {
      throw ResultEmailException(
        'The class has no assigned teacher.',
        statusCode: 409,
      );
    }

    if (!isAdmin && ownerTeacherId != actorId) {
      throw ResultEmailException(
        'You are not assigned to this class.',
        statusCode: 403,
      );
    }

    // Reuse the existing scorebook and grading calculations.
    final book = await MySubjectsService.scorebook(
      ownerTeacherId,
      classId,
    );

    final assessments = (book['assessments'] as List)
        .cast<Map<String, dynamic>>();

    Map<String, dynamic>? selectedExam;

    for (final assessment in assessments) {
      if (assessment['id'] == examId) {
        selectedExam = assessment;
        break;
      }
    }

    if (selectedExam == null) {
      throw ResultEmailException(
        'This exam is not assigned to the selected class.',
        statusCode: 404,
      );
    }

    final examTitle = selectedExam['title']?.toString() ?? 'Exam';

    final students = (book['students'] as List).cast<Map<String, dynamic>>();

    // Validate that the configured test student belongs to this class.
    if (testMode) {
      final testStudentRows = await Database.pool.execute(
        Sql.named('''
          SELECT id
          FROM students
          WHERE id = @student_id
            AND class_id = @class_id
        '''),
        parameters: {
          'student_id': testStudentId,
          'class_id': classId,
        },
      );

      if (testStudentRows.isEmpty) {
        throw ResultEmailException(
          'The configured test student does not belong to this class.',
          statusCode: 400,
        );
      }
    }

    // Load student email addresses.
    final emailRows = await Database.pool.execute(
      Sql.named('''
        SELECT id, email
        FROM students
        WHERE class_id = @class_id
      '''),
      parameters: {'class_id': classId},
    );

    final emails = <int, String>{};

    for (final row in emailRows) {
      final studentId = row[0] as int?;

      if (studentId == null) continue;

      final email = row[1]?.toString().trim() ?? '';

      if (email.isNotEmpty) {
        emails[studentId] = email;
      }
    }

    // Move pending emails older than 30 minutes to manual review.
    // These emails must not be automatically resent.
    final stalePendingRows = await Database.pool.execute(
      Sql.named('''
        UPDATE email_logs
        SET status = 'needs_review',
            error_message =
              'Pending email exceeded the 30-minute review threshold. '
              'Verify delivery before retrying.'
        WHERE exam_id = @exam_id
          AND status = 'pending'
          AND COALESCE(last_attempt_at, created_at)
              < NOW() - INTERVAL '30 minutes'
          AND EXISTS (
            SELECT 1
            FROM students s
            WHERE s.id = email_logs.student_id
              AND s.class_id = @class_id
          )
        RETURNING id
      '''),
      parameters: {
        'exam_id': examId,
        'class_id': classId,
      },
    );

    var sent = 0;
    var failed = 0;
    var needsReview = 0;
    var skippedNoEmail = 0;
    var skippedNotFinal = 0;
    var skippedDuplicate = 0;
    var skippedNeedsReview = 0;

    for (final student in students) {
      final studentId = student['id'] as int;

      // In test mode, process only the configured test student.
      if (testMode && studentId != testStudentId) {
        continue;
      }

      final email = testMode ? testRecipient : emails[studentId];

      if (email == null || email.isEmpty) {
        skippedNoEmail++;
        continue;
      }

      final cells = (student['cells'] as List).cast<Map<String, dynamic>>();

      Map<String, dynamic>? result;

      for (final cell in cells) {
        if (cell['exam_id'] == examId) {
          result = cell;
          break;
        }
      }

      // Only send results finalized in the existing scorebook.
      if (result == null || result['status'] != 'completed') {
        skippedNotFinal++;
        continue;
      }

      final score = result['score'] as num?;
      final maxScore = result['max_score'] as num?;

      if (score == null || maxScore == null || maxScore <= 0) {
        skippedNotFinal++;
        continue;
      }

      final firstName = student['first_name']?.toString() ?? '';
      final lastName = student['last_name']?.toString() ?? '';
      final studentName = '$firstName $lastName'.trim();
      final studentNumber = student['student_number']?.toString() ?? '';

      // Create a pending log or retry an existing failed log.
      // Sent, pending, and needs_review records cannot be retried here.
      final logRows = await Database.pool.execute(
        Sql.named('''
          INSERT INTO email_logs (
            student_id,
            exam_id,
            recipient_email,
            status,
            last_attempt_at
          )
          VALUES (
            @student_id,
            @exam_id,
            @email,
            'pending',
            NOW()
          )
          ON CONFLICT (student_id, exam_id)
          DO UPDATE SET
            recipient_email = EXCLUDED.recipient_email,
            status = 'pending',
            last_attempt_at = NOW(),
            sent_at = NULL,
            error_message = NULL
          WHERE email_logs.status = 'failed'
          RETURNING id
        '''),
        parameters: {
          'student_id': studentId,
          'exam_id': examId,
          'email': email,
        },
      );

      // No returned row means an existing record prevented the send.
      if (logRows.isEmpty) {
        final existingRows = await Database.pool.execute(
          Sql.named('''
            SELECT status
            FROM email_logs
            WHERE student_id = @student_id
              AND exam_id = @exam_id
          '''),
          parameters: {
            'student_id': studentId,
            'exam_id': examId,
          },
        );

        if (existingRows.isNotEmpty &&
            existingRows.first[0]?.toString() == 'needs_review') {
          skippedNeedsReview++;
        } else {
          skippedDuplicate++;
        }

        continue;
      }

      final logId = logRows.first[0] as int?;

      if (logId == null) {
        throw ResultEmailException(
          'Could not create the email log.',
          statusCode: 500,
        );
      }

      var emailAccepted = false;

      try {
        await _sendEmail(
          apiKey: apiKey,
          fromEmail: fromEmail,
          toEmail: email,
          studentName: studentName,
          studentNumber: studentNumber,
          examTitle: examTitle,
          score: score,
          maxScore: maxScore,
          studentId: studentId,
          examId: examId,
        );

        emailAccepted = true;
      } on ResendHttpException catch (e) {
        // Resend 4xx responses are treated as rejected requests.
        await Database.pool.execute(
          Sql.named('''
            UPDATE email_logs
            SET status = 'failed',
                error_message = @error
            WHERE id = @id
          '''),
          parameters: {
            'id': logId,
            'error': _limitError(e.toString()),
          },
        );

        failed++;
      } catch (e) {
        // Network errors, timeouts, and uncertain responses require review.
        // Do not automatically resend an email that may have been accepted.
        await Database.pool.execute(
          Sql.named('''
            UPDATE email_logs
            SET status = 'needs_review',
                error_message = @error
            WHERE id = @id
          '''),
          parameters: {
            'id': logId,
            'error': _limitError(e.toString()),
          },
        );

        needsReview++;
      }

      // Keep this database update outside the sending try/catch.
      // If this update fails after Resend accepted the email, the record
      // remains pending and will eventually be moved to needs_review.
      if (emailAccepted) {
        await Database.pool.execute(
          Sql.named('''
            UPDATE email_logs
            SET status = 'sent',
                sent_at = NOW(),
                error_message = NULL
            WHERE id = @id
          '''),
          parameters: {'id': logId},
        );

        sent++;
      }
    }

    return {
      'exam_id': examId,
      'exam_title': examTitle,
      'test_mode': testMode,
      'total_students': testMode ? 1 : students.length,
      'sent': sent,
      'failed': failed,
      'needs_review': needsReview,
      'skipped_no_email': skippedNoEmail,
      'skipped_not_final': skippedNotFinal,
      'skipped_duplicate': skippedDuplicate,
      'skipped_needs_review': skippedNeedsReview,
      'stale_pending_reviewed': stalePendingRows.length,
    };
  }

  /// Sends an individual result email using Resend.
  static Future<void> _sendEmail({
    required String apiKey,
    required String fromEmail,
    required String toEmail,
    required String studentName,
    required String studentNumber,
    required String examTitle,
    required num score,
    required num maxScore,
    required int studentId,
    required int examId,
  }) async {
    final percentage = (score / maxScore) * 100;

    final html =
        '''
      <!DOCTYPE html>
      <html>
        <body style="font-family: Arial, sans-serif; color: #1f2937;">
          <h2>CheckMate Exam Results</h2>
          <p>Hello ${_escapeHtml(studentName)},</p>
          <p>Your exam result is now available.</p>
          <p><strong>Exam:</strong> ${_escapeHtml(examTitle)}</p>
          <p><strong>Student Number:</strong> ${_escapeHtml(studentNumber)}</p>
          <h3>Your Score: $score / $maxScore</h3>
          <p><strong>Percentage:</strong> ${percentage.toStringAsFixed(2)}%</p>
          <p>This is an automatically generated result from CheckMate.</p>
        </body>
      </html>
    ''';

    final response = await http
        .post(
          Uri.parse('https://api.resend.com/emails'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Idempotency-Key': 'checkmate-exam-result/$examId/$studentId',
          },
          body: jsonEncode({
            'from': fromEmail,
            'to': [toEmail],
            'subject': 'Your CheckMate Exam Result: $examTitle',
            'html': html,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 400 && response.statusCode < 500) {
      throw ResendHttpException(
        response.statusCode,
        'Resend error (${response.statusCode}): ${response.body}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Uncertain Resend response '
        '(${response.statusCode}): ${response.body}',
      );
    }
  }

  /// Limits stored error messages to 1,000 characters.
  static String _limitError(String error) {
    return error.substring(0, error.length > 1000 ? 1000 : error.length);
  }

  /// Escapes HTML special characters in email content.
  static String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
