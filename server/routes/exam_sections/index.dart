import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../lib/exam_sections/exam_section_service.dart';

const allowedQuestionTypes = {
  'identification',
  'true_false',
  'multiple_choice',
};

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    final examId = int.tryParse(
      context.request.uri.queryParameters['exam_id'] ?? '',
    );

    if (examId == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'status': 'error',
          'message': 'exam_id query parameter is required',
        },
      );
    }

    try {
      final sections = await ExamSectionService.getByExam(
        examId,
      );

      return Response.json(
        body: {
          'status': 'ok',
          'sections': sections,
        },
      );
    } catch (e) {
      return Response.json(
        statusCode: 500,
        body: {
          'status': 'error',
          'message': e.toString(),
        },
      );
    }
  }

  if (context.request.method == HttpMethod.post) {
    try {
      final decodedBody = jsonDecode(
        await context.request.body(),
      );

      if (decodedBody is! Map<String, dynamic>) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Invalid request body',
          },
        );
      }

      final body = decodedBody;

      final examId = int.tryParse(
        body['exam_id']?.toString() ?? '',
      );

      final name = body['name']?.toString().trim();

      final questionType = body['question_type']
          ?.toString()
          .trim()
          .toLowerCase();

      final sectionOrder = int.tryParse(
        body['section_order']?.toString() ?? '',
      );

      final defaultPoints = num.tryParse(
        body['default_points']?.toString() ?? '1',
      );

      if (examId == null) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'exam_id is required',
          },
        );
      }

      if (name == null || name.isEmpty) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Section name is required',
          },
        );
      }

      if (questionType == null ||
          !allowedQuestionTypes.contains(questionType)) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'Invalid question type. Use identification, '
                'true_false, or multiple_choice.',
          },
        );
      }

      if (sectionOrder == null || sectionOrder < 1) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'Section order must be at least 1',
          },
        );
      }

      if (defaultPoints == null || defaultPoints < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'Default points cannot be negative',
          },
        );
      }

      final section = await ExamSectionService.create(
        examId: examId,
        name: name,
        questionType: questionType,
        sectionOrder: sectionOrder,
        defaultPoints: defaultPoints,
      );

      return Response.json(
        statusCode: 201,
        body: {
          'status': 'ok',
          'section': section,
        },
      );
    } catch (e) {
      return Response.json(
        statusCode: 500,
        body: {
          'status': 'error',
          'message': e.toString(),
        },
      );
    }
  }

  return Response.json(
    statusCode: 405,
    body: {
      'status': 'error',
      'message': 'Method not allowed',
    },
  );
}