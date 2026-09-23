import 'package:dart_frog/dart_frog.dart';

Handler middleware(Handler handler) {
  return (context) async {
    if (context.request.method == HttpMethod.options) {
      return Response(
        statusCode: 204,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods':
              'GET, POST, PUT, PATCH, DELETE, OPTIONS',
          'Access-Control-Allow-Headers':
              'Origin, Content-Type, Accept, Authorization',
        },
      );
    }

    final response = await handler(context);

    return response.copyWith(
      headers: {
        ...response.headers,
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods':
            'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        'Access-Control-Allow-Headers':
            'Origin, Content-Type, Accept, Authorization',
      },
    );
  };
}
