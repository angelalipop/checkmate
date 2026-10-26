import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/exam_sections/exam_section_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final method = context.request.method;

  if (method != HttpMethod.delete && method != HttpMethod.patch) {
    return Response.json(
      statusCode: 405,
      body: {'message': 'Method not allowed'},
    );
  }

  final parsedId = int.tryParse(id);
  if (parsedId == null || parsedId < 1) {
    return Response.json(statusCode: 400, body: {'message': 'Invalid ID'});
  }

  // The parent folder's authMiddleware verifies the JWT and active account.
  final user = context.read<Map<String, dynamic>>();
  final userId = int.tryParse(user['userId']?.toString() ?? '');
  final role = user['role']?.toString() ?? '';
  if (userId == null || (role != 'admin' && role != 'teacher')) {
    return Response.json(
      statusCode: 403,
      body: {'message': 'Permission denied'},
    );
  }

  if (method == HttpMethod.patch) {
    return _patch(context, parsedId, userId: userId, role: role);
  }

  try {
    final deleted = await ExamSectionService.deleteDraftSection(
      parsedId,
      userId: userId,
      role: role,
    );
    if (!deleted) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Not found or deletion not permitted. Check ownership, draft status, and existing attempts.',
        },
      );
    }
    return Response.json(
      body: {'status': 'ok', 'message': 'Deleted successfully'},
    );
  } catch (e) {
    // ignore: avoid_print
    print('DELETE EXAM_SECTION ERROR: $e');
    return Response.json(
      statusCode: 500,
      body: {'message': 'Unable to delete.'},
    );
  }
}

Future<Response> _patch(
  RequestContext context,
  int sectionId, {
  required int userId,
  required String role,
}) async {
  try {
    final decoded = jsonDecode(await context.request.body());

    if (decoded is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {'message': 'Invalid request body'},
      );
    }

    final name = decoded['name']?.toString().trim() ?? '';
    final points = num.tryParse(decoded['default_points']?.toString() ?? '');

    if (name.isEmpty || points == null || points <= 0) {
      return Response.json(
        statusCode: 400,
        body: {
          'message': 'A section name and points greater than zero are required',
        },
      );
    }

    final section = await ExamSectionService.updateDraftSection(
      sectionId,
      userId: userId,
      role: role,
      name: name,
      defaultPoints: points,
    );

    if (section == null) {
      return Response.json(
        statusCode: 409,
        body: {
          'message':
              'Not found or update not permitted. Check ownership, draft status, and existing attempts.',
        },
      );
    }

    return Response.json(
      body: {'status': 'ok', 'section': section},
    );
  } catch (e) {
    // ignore: avoid_print
    print('PATCH EXAM_SECTION ERROR: $e');
    return Response.json(
      statusCode: 500,
      body: {'message': 'Unable to update section.'},
    );
  }
}
