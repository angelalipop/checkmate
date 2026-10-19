import 'package:dart_frog/dart_frog.dart';
import 'package:postgres/postgres.dart';

import 'package:server/sections/section_service.dart';

Response _error(int status, String message) => Response.json(
      statusCode: status,
      body: {'status': 'error', 'message': message},
    );

Future<Response> onRequest(RequestContext context) async {
  try {
    final user = context.read<Map<String, dynamic>>();
    final isAdmin = user['role'] == 'admin';

    switch (context.request.method) {
      case HttpMethod.get:
        return Response.json(
          body: {'status': 'ok', 'sections': await SectionService.getAll()},
        );

      case HttpMethod.post:
        if (!isAdmin) return _error(403, 'Administrator access required.');

        final body = await context.request.json();
        if (body is! Map) return _error(400, 'Invalid request body');

        final programId = int.tryParse('${body['program_id']}');
        final yearLevel = int.tryParse('${body['year_level']}');
        final semester = int.tryParse('${body['semester']}');
        if (programId == null) return _error(400, 'Program is required');
        if (yearLevel == null) return _error(400, 'Year level is required');
        if (semester == null) return _error(400, 'Semester is required');

        final section = await SectionService.create(
          programId: programId,
          name: '${body['name'] ?? ''}',
          yearLevel: yearLevel,
          schoolYear: '${body['school_year'] ?? ''}'.trim(),
          semester: semester,
        );
        return Response.json(
          statusCode: 201,
          body: {'status': 'ok', 'section': section},
        );

      default:
        return _error(405, 'Method not allowed');
    }
  } on ArgumentError catch (e) {
    return _error(400, '${e.message}');
  } on ServerException catch (e) {
    if (e.code == '23505') {
      return _error(409, 'This section already exists for that term.');
    }
    // ignore: avoid_print
    print('SECTIONS ROUTE ERROR: $e');
    return _error(500, 'Internal server error');
  } catch (e) {
    // ignore: avoid_print
    print('SECTIONS ROUTE ERROR: $e');
    return _error(500, 'Internal server error');
  }
}
