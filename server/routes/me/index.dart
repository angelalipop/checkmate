import 'package:dart_frog/dart_frog.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    final user = context.read<Map<String, dynamic>>();

    return Response.json(
      body: {
        'status': 'ok',
        'user': user,
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
