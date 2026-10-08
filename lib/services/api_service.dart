import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiService {
  static String get baseUrl {
    if (kIsWeb) {
      return 'http://localhost:8080';
    }
    // Physical iPhone → Mac running the CheckMate backend.
    return 'http://10.0.2.2:8080';
  }

  // =========================
  // LOGIN
  // =========================

  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Login failed',
      );
    }

    return data;
  }

  // =========================
  // CURRENT USER / SESSION
  // =========================

  static Future<Map<String, dynamic>> getCurrentUser(
    String token,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/me'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Session expired',
      );
    }

    return data;
  }

  // =========================
  // GET SUBJECTS
  // =========================

  static Future<List<Map<String, dynamic>>> getSubjects(
    String token,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/subjects'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to load subjects',
      );
    }

    final subjects = data['subjects'];

    if (subjects is! List) {
      throw Exception(
        'Invalid subjects data received.',
      );
    }

    return subjects
        .map(
          (subject) =>
              Map<String, dynamic>.from(subject as Map),
        )
        .toList();
  }

  // =========================
  // CREATE SUBJECT
  // =========================

  static Future<Map<String, dynamic>> createSubject({
    required String token,
    required String name,
    String? code,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/subjects'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'name': name,
        'code': code,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 201) {
      throw Exception(
        data['message'] ?? 'Failed to create subject',
      );
    }

    final subject = data['subject'];

    if (subject is! Map) {
      throw Exception(
        'Invalid subject data received.',
      );
    }

    return Map<String, dynamic>.from(subject);
  }

  // =========================
  // GET CLASSES
  // =========================

  static Future<List<Map<String, dynamic>>> getClasses(
    String token,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/classes'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to load classes',
      );
    }

    final classes = data['classes'];

    if (classes is! List) {
      throw Exception(
        'Invalid classes data received.',
      );
    }

    return classes
        .map(
          (item) =>
              Map<String, dynamic>.from(item as Map),
        )
        .toList();
  }

  // =========================
  // CREATE CLASS
  // =========================

  static Future<Map<String, dynamic>> createClass({
    required String token,
    required int subjectId,
    int? teacherId,
    required String section,
    String? schoolYear,
    String? semester,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/classes'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'subject_id': subjectId,
        'teacher_id': teacherId,
        'section': section,
        'school_year': schoolYear,
        'semester': semester,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 201) {
      throw Exception(
        data['message'] ?? 'Failed to create class',
      );
    }

    final newClass = data['class'];

    if (newClass is! Map) {
      throw Exception(
        'Invalid class data received.',
      );
    }

    return Map<String, dynamic>.from(newClass);
  }

  // =========================
  // GET TEACHERS
  // =========================

  static Future<List<Map<String, dynamic>>> getTeachers(
    String token,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/teachers'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to load teachers',
      );
    }

    final teachers = data['teachers'];

    if (teachers is! List) {
      throw Exception(
        'Invalid teachers data received.',
      );
    }

    return teachers
        .map(
          (teacher) =>
              Map<String, dynamic>.from(teacher as Map),
        )
        .toList();
  }

  // =========================
  // GET STUDENTS
  // =========================

  static Future<List<Map<String, dynamic>>> getStudents(
    String token, {
    int? classId,
  }) async {
    final uri = classId == null
        ? Uri.parse('$baseUrl/students')
        : Uri.parse(
            '$baseUrl/students?class_id=$classId',
          );

    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to load students',
      );
    }

    final students = data['students'];

    if (students is! List) {
      throw Exception(
        'Invalid students data received.',
      );
    }

    return students
        .map(
          (student) =>
              Map<String, dynamic>.from(student as Map),
        )
        .toList();
  }

  // =========================
  // CREATE STUDENT
  // =========================

  static Future<Map<String, dynamic>> createStudent({
    required String token,
    required int classId,
    required String studentNumber,
    required String firstName,
    required String lastName,
    String? email,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/students'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'class_id': classId,
        'student_number': studentNumber,
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 201) {
      throw Exception(
        data['message'] ?? 'Failed to create student',
      );
    }

    final student = data['student'];

    if (student is! Map) {
      throw Exception(
        'Invalid student data received.',
      );
    }

    return Map<String, dynamic>.from(student);
  }

  // =========================
  // UPDATE STUDENT
  // =========================

  static Future<Map<String, dynamic>> updateStudent({
    required String token,
    required int studentId,
    String? email,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/students/$studentId'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'email': email,
      }),
    );

    Map<String, dynamic> data = {};

    try {
      final decoded = jsonDecode(response.body);

      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {
      // Non-JSON body; handled by the status check below.
    }

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to update student',
      );
    }

    final student = data['student'];

    return student is Map ? Map<String, dynamic>.from(student) : data;
  }

  // =========================
  // GET EXAMS
  // =========================

  static Future<List<Map<String, dynamic>>> getExams(
    String token, {
    int? classId,
  }) async {
    final uri = classId == null
        ? Uri.parse('$baseUrl/exams')
        : Uri.parse(
            '$baseUrl/exams?class_id=$classId',
          );

    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message'] ?? 'Failed to load exams',
      );
    }

    final exams = data['exams'];

    if (exams is! List) {
      throw Exception(
        'Invalid exams data received.',
      );
    }

    return exams
        .map(
          (exam) =>
              Map<String, dynamic>.from(exam as Map),
        )
        .toList();
  }

  // =========================
  // CREATE EXAM
  // =========================

  static Future<Map<String, dynamic>> createExam({
    required String token,
    required int classId,
    required String title,
    String? description,
    String? instructions,
    String? status,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/exams'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'class_id': classId,
        'title': title,
        'description': description,
        'instructions': instructions,
        'status': status,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 201) {
      throw Exception(
        data['message'] ?? 'Failed to create exam',
      );
    }

    final exam = data['exam'];

    if (exam is! Map) {
      throw Exception(
        'Invalid exam data received.',
      );
    }

    return Map<String, dynamic>.from(exam);
  }

  // =========================
  // GET EXAM SECTIONS
  // =========================

  static Future<List<Map<String, dynamic>>> getExamSections(
    String token,
    int examId,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/exam_sections?exam_id=$examId',
    );

    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ??
            'Failed to load exam sections.',
      );
    }

    final sections = data['sections'];

    if (sections is! List) {
      throw Exception(
        'Invalid exam sections data received.',
      );
    }

    return sections
        .map(
          (section) =>
              Map<String, dynamic>.from(section as Map),
        )
        .toList();
  }
    // =========================
  // GET QUESTIONS
  // =========================

  static Future<List<Map<String, dynamic>>> getQuestions(
    String token,
    int sectionId,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/questions?section_id=$sectionId',
    );

    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ??
            'Failed to load questions.',
      );
    }

    final questions = data['questions'];

    if (questions is! List) {
      throw Exception(
        'Invalid questions data received.',
      );
    }

    return questions
        .map(
          (question) =>
              Map<String, dynamic>.from(
                question as Map,
              ),
        )
        .toList();
  }
    // =========================
  // CREATE QUESTION
  // =========================

  static Future<Map<String, dynamic>> createQuestion({
    required String token,
    required int sectionId,
    required int questionNumber,
    required String questionText,
    required num points,
    dynamic choices,
    String? correctAnswer,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/questions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'section_id': sectionId,
        'question_number': questionNumber,
        'question_text': questionText,
        'points': points,
        'choices': choices,
        'correct_answer': correctAnswer,
      }),
    );

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 201) {
      throw Exception(
        data['message']?.toString() ??
            'Failed to create question.',
      );
    }

    final question = data['question'];

    if (question is! Map) {
      throw Exception(
        'Invalid question data received.',
      );
    }

    return Map<String, dynamic>.from(question);
  }
  static Future<List<Map<String, dynamic>>> getAcceptableAnswers(
  String token,
  int questionId,
) async {
  final uri = Uri.parse(
    '$baseUrl/acceptable_answers?question_id=$questionId',
  );

  final response = await http.get(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    },
  );

  final data =
      jsonDecode(response.body) as Map<String, dynamic>;

  if (response.statusCode != 200) {
    throw Exception(
      data['message']?.toString() ??
          'Failed to load acceptable answers.',
    );
  }

  final answers = data['answers'];

  if (answers is! List) {
    throw Exception(
      'Invalid acceptable answers data received.',
    );
  }

  return answers
      .map(
        (answer) =>
            Map<String, dynamic>.from(
              answer as Map,
            ),
      )
      .toList();
}

static Future<Map<String, dynamic>> createAcceptableAnswer({
  required String token,
  required int questionId,
  required String answer,
}) async {
  final response = await http.post(
    Uri.parse('$baseUrl/acceptable_answers'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    },
    body: jsonEncode({
      'question_id': questionId,
      'answer': answer,
    }),
  );

  final data =
      jsonDecode(response.body) as Map<String, dynamic>;

  if (response.statusCode != 201) {
    throw Exception(
      data['message']?.toString() ??
          'Failed to add acceptable answer.',
    );
  }

  final answerData = data['answer'];

  if (answerData is! Map) {
    throw Exception(
      'Invalid acceptable answer data received.',
    );
  }

  return Map<String, dynamic>.from(answerData);
  }

  // =========================
  // TEACHER MANAGEMENT (ADMIN ONLY)
  // =========================
  //
  // Backend contract (all require an admin Bearer token):
  //   POST   /teachers                    -> 201 { teacher }
  //   PUT    /teachers/:id                -> 200 { teacher }
  //   PUT    /teachers/:id/classes        -> 200 { teacher }
  //   POST   /teachers/:id/reset-password -> 200 { temporary_password }
  //   PATCH  /teachers/:id/active         -> 200 { teacher }
  //   DELETE /teachers/:id                -> 200 { message }

  static Map<String, String> _authHeaders(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  /// Decodes a JSON object body, tolerating empty / non-JSON responses.
  static Map<String, dynamic> _decodeBody(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Non-JSON body; callers rely on the status code instead.
    }
    return <String, dynamic>{};
  }



  /// Retrieves a list of all teacher departments.
  static Future<List<String>> getTeacherDepartments(String token) async {
  final response = await http.get(
    Uri.parse('$baseUrl/teacher_departments'),
    headers: _authHeaders(token),
  );

  final data = _decodeBody(response);

  if (response.statusCode != 200) {
    throw Exception(
      data['message']?.toString() ?? 'Failed to load teacher departments',
    );
  }

  final departments = data['departments'];

  if (departments is! List) {
    return <String>[];
  }

  return departments.map((item) => item.toString()).toList();
}

  /// [assignments]: [{subject_id, section, school_year, semester}, ...]
  /// A Subject + Section already owned by another teacher => HTTP 409.
  static Future<Map<String, dynamic>> createTeacher({
    required String token,
    required String teacherIdNo,
    required String firstName,
    String middleName = '',
    required String lastName,
   required String department,
   required String temporaryPassword,
    List<Map<String, dynamic>> assignments = const [],
}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/teachers'),
     headers: _authHeaders(token),
     body: jsonEncode({
      'teacher_id_no': teacherIdNo,
      'first_name': firstName,
      'middle_name': middleName,
      'last_name': lastName,
      'department': department,
      'temporary_password': temporaryPassword,
      'assignments': assignments,
      }),
  );  

  final data = _decodeBody(response);

  if (response.statusCode != 201) {
    throw Exception(
      data['message']?.toString() ?? 'Failed to create teacher',
    );
  }

  final teacher = data['teacher'];

  return teacher is Map ? Map<String, dynamic>.from(teacher) : data;
}

  /// Pass [assignments] to change them in the same transaction as the
  /// profile; leave it null to keep the teacher's assignments untouched.
  static Future<Map<String, dynamic>> updateTeacher({
  required String token,
  required int teacherId,
  required String teacherIdNo,
  required String firstName,
  String middleName = '',
  required String lastName,
  required String department,
  bool? isActive,
  List<Map<String, dynamic>>? assignments,
}) async {
  final response = await http.put(
    Uri.parse('$baseUrl/teachers/$teacherId'),
    headers: _authHeaders(token),
    body: jsonEncode({
      'teacher_id_no': teacherIdNo,
      'first_name': firstName,
      'middle_name': middleName,
      'last_name': lastName,
      'department': department,
      if (isActive != null) 'is_active': isActive,
      if (assignments != null) 'assignments': assignments,
    }),
  );

  final data = _decodeBody(response);

  if (response.statusCode != 200) {
    throw Exception(
      data['message']?.toString() ?? 'Failed to update teacher',
    );
  }

  final teacher = data['teacher'];

  return teacher is Map
      ? Map<String, dynamic>.from(teacher)
      : data;
}


  /// Replaces the teacher's whole set of Subject + Section assignments.
  static Future<Map<String, dynamic>> setTeacherAssignments({
    required String token,
    required int teacherId,
    required List<Map<String, dynamic>> assignments,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/teachers/$teacherId/assignments'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'assignments': assignments,
      }),
    );

    final data = _decodeBody(response);

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ?? 'Failed to update assignments',
      );
    }

    final teacher = data['teacher'];

    return teacher is Map ? Map<String, dynamic>.from(teacher) : data;
  }

  /// Every known section with its current owner for [subjectId].
  /// Rows: {section, school_year, semester, year_level,
  ///        class_id, teacher_id, teacher_name}
  static Future<List<Map<String, dynamic>>> getTeachingOptions(
    String token,
    int subjectId,
  ) async {
    final response = await http.get(
      Uri.parse('$baseUrl/teaching-options?subject_id=$subjectId'),
      headers: _authHeaders(token),
    );

    final data = _decodeBody(response);

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ?? 'Failed to load sections',
      );
    }

    final sections = data['sections'];

    if (sections is! List) {
      return [];
    }

    return sections
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Returns the newly generated temporary password (shown once by the UI).
  static Future<String> resetTeacherPassword({
    required String token,
    required int teacherId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/teachers/$teacherId/reset-password'),
      headers: _authHeaders(token),
    );

    final data = _decodeBody(response);

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ?? 'Failed to reset password',
      );
    }

    final password = data['temporary_password']?.toString();

    if (password == null || password.isEmpty) {
      throw Exception(
        'Password was reset, but no temporary password was returned.',
      );
    }

    return password;
  }

  static Future<Map<String, dynamic>> setTeacherActive({
    required String token,
    required int teacherId,
    required bool active,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/teachers/$teacherId/active'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'is_active': active,
      }),
    );

    final data = _decodeBody(response);

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ??
            (active
                ? 'Failed to enable account'
                : 'Failed to disable account'),
      );
    }

    final teacher = data['teacher'];

    return teacher is Map ? Map<String, dynamic>.from(teacher) : data;
  }

  static Future<void> deleteTeacher({
    required String token,
    required int teacherId,
  }) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/teachers/$teacherId'),
      headers: _authHeaders(token),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      final data = _decodeBody(response);

      throw Exception(
        data['message']?.toString() ?? 'Failed to delete teacher',
      );
    }
  }

  // =========================
  // CHANGE PASSWORD (own account)
  // =========================

  static Future<void> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/change-password'),
      headers: _authHeaders(token),
      body: jsonEncode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );

    final data = _decodeBody(response);

    if (response.statusCode != 200) {
      throw Exception(
        data['message']?.toString() ?? 'Failed to change password',
      );
    }
  }
}
