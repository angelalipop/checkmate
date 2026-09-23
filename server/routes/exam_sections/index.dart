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
      final sections = await ExamSectionService.getByExam(examId);

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
      final body =
          jsonDecode(await context.request.body()) as Map<String, dynamic>;

      final examId = body['exam_id'];
      final name = body['name'];
      final questionType = body['question_type'];
      final sectionOrder = body['section_order'];
      final defaultPoints = body['default_points'] ?? 1;

      if (examId is! int ||
          name is! String ||
          name.trim().isEmpty ||
          questionType is! String ||
          !allowedQuestionTypes.contains(questionType) ||
          sectionOrder is! int ||
          defaultPoints is! num ||
          defaultPoints < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'exam_id, name, valid question_type, section_order, '
                'and non-negative default_points are required',
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
