import 'package:dart_frog/dart_frog.dart';
import 'package:postgres/postgres.dart';

import '../../lib/database.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    final result = await Database.pool.execute(
      Sql.named('SELECT current_database() AS database_name'),
    );

    final databaseName = result.first.toColumnMap()['database_name'];

    return Response.json(
      body: {
        'status': 'ok',
        'database': databaseName,
      },
    );
  } catch (error) {
    return Response.json(
      statusCode: 500,
      body: {
        'status': 'error',
        'message': error.toString(),
      },
    );
  }
}
