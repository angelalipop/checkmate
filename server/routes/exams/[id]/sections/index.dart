import 'package:dart_frog/dart_frog.dart';

import '../../../../lib/exams/exam_section_service.dart';

Future<Response> onRequest(
  RequestContext context,
  String id,
) async {
  final examId = int.tryParse(id);

  if (examId == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'status': 'error',
        'message': 'Invalid exam id',
      },
    );
  }

  if (context.request.method == HttpMethod.get) {
    try {
      final sections = await ExamSectionService.getAll(
        examId: examId,
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
      final body = await context.request.json();

      if (body is! Map) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message': 'Invalid request body',
          },
        );
      }

      final name = body['name']?.toString();
      final questionType = body['question_type']?.toString();

      final sectionOrder = body['section_order'] is int
          ? body['section_order'] as int
          : int.tryParse(
              body['section_order']?.toString() ?? '',
            );

      final defaultPoints = body['default_points'] is num
          ? body['default_points'] as num
          : num.tryParse(
              body['default_points']?.toString() ?? '',
            ) ??
            1;

      const validQuestionTypes = {
        'identification',
        'true_false',
        'multiple_choice',
      };

      if (name == null ||
          name.trim().isEmpty ||
          questionType == null ||
          !validQuestionTypes.contains(questionType) ||
          sectionOrder == null ||
          sectionOrder < 1 ||
          defaultPoints < 0) {
        return Response.json(
          statusCode: 400,
          body: {
            'status': 'error',
            'message':
                'name, valid question_type, section_order, and valid default_points are required',
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
