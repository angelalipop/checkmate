import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiService {
  static String get baseUrl {
    if (kIsWeb) {
      return 'http://localhost:8080';
    }
    // Physical iPhone → Mac running the CheckMate backend.
    return 'http://192.168.100.247:8080';
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
    required int teacherId,
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
}