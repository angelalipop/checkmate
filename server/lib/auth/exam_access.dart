import 'package:dart_frog/dart_frog.dart';
import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

/// The verified user attached by authMiddleware.
class ExamActor {
  const ExamActor({required this.id, required this.role});

  final int id;
  final String role;

  bool get isAdmin => role == 'admin';

  /// Null when there is no verified admin / teacher on the request.
  static ExamActor? fromContext(RequestContext context) {
    try {
      final user = context.read<Map<String, dynamic>>();
      final id = int.tryParse(user['userId']?.toString() ?? '');
      final role = user['role']?.toString() ?? '';

      if (id == null || (role != 'admin' && role != 'teacher')) {
        return null;
      }

      return ExamActor(id: id, role: role);
    } catch (_) {
      return null;
    }
  }
}

/// Ownership checks for exam data.
///
/// Admins may access everything. A teacher may only touch data that belongs
/// to a class where classes.teacher_id is that teacher. Each guard returns
/// null when access is allowed, otherwise the error Response to return.
class ExamAccess {
  ExamAccess._();

  static Future<Response?> guardClass(RequestContext context, int classId) {
    return _guard(
      context,
      'You are not assigned to this class.',
      (a) => _exists(
        'SELECT 1 FROM classes WHERE id = @id AND teacher_id = @user_id',
        classId,
        a.id,
      ),
    );
  }

  static Future<Response?> guardExam(RequestContext context, int examId) {
    return _guard(
      context,
      'You do not have access to this exam.',
      (a) => _exists(
        '''
        SELECT 1
        FROM exams e
        JOIN classes c ON c.id = e.class_id
        WHERE e.id = @id AND c.teacher_id = @user_id
        ''',
        examId,
        a.id,
      ),
    );
  }

  static Future<Response?> guardSection(
    RequestContext context,
    int sectionId,
  ) {
    return _guard(
      context,
      'You do not have access to this section.',
      (a) => _exists(
        '''
        SELECT 1
        FROM exam_sections s
        JOIN exams e ON e.id = s.exam_id
        JOIN classes c ON c.id = e.class_id
        WHERE s.id = @id AND c.teacher_id = @user_id
        ''',
        sectionId,
        a.id,
      ),
    );
  }

  static Future<Response?> guardAttempt(
    RequestContext context,
    int attemptId,
  ) {
    return _guard(
      context,
      'You do not have access to this attempt.',
      (a) => _exists(
        '''
        SELECT 1
        FROM exam_attempts t
        JOIN exams e ON e.id = t.exam_id
        JOIN classes c ON c.id = e.class_id
        WHERE t.id = @id AND c.teacher_id = @user_id
        ''',
        attemptId,
        a.id,
      ),
    );
  }

  static Future<Response?> guardQuestion(
    RequestContext context,
    int questionId,
  ) {
    return _guard(
      context,
      'You do not have access to this question.',
      (a) => _exists(
        '''
        SELECT 1
        FROM questions q
        JOIN exam_sections s ON s.id = q.section_id
        JOIN exams e ON e.id = s.exam_id
        JOIN classes c ON c.id = e.class_id
        WHERE q.id = @id AND c.teacher_id = @user_id
        ''',
        questionId,
        a.id,
      ),
    );
  }

  static Future<Response?> _guard(
    RequestContext context,
    String deniedMessage,
    Future<bool> Function(ExamActor actor) check,
  ) async {
    final actor = ExamActor.fromContext(context);

    if (actor == null) {
      return deny(403, 'Teacher or administrator access required.');
    }

    // Admins pass; a missing record then gets the route's normal 404/409.
    if (actor.isAdmin) return null;

    try {
      if (await check(actor)) return null;
      return deny(403, deniedMessage);
    } catch (e) {
      // ignore: avoid_print
      print('EXAM ACCESS CHECK ERROR: $e');
      return deny(500, 'Unable to verify access.');
    }
  }

  static Future<bool> _exists(String sql, int id, int userId) async {
    final result = await Database.pool.execute(
      Sql.named(sql),
      parameters: {'id': id, 'user_id': userId},
    );
    return result.isNotEmpty;
  }

  /// A JSON error response in the format the routes already use.
  static Response deny(int statusCode, String message) {
    return Response.json(
      statusCode: statusCode,
      body: {'status': 'error', 'message': message},
    );
  }
}
