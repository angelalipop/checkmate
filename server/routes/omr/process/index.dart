import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../../lib/omr/opencv_omr_processor.dart';

const Map<String, String> _corsHeaders = <String, String>{
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

Future<Response> onRequest(RequestContext context) async {
  final request = context.request;

  if (request.method == HttpMethod.options) {
    return Response(statusCode: 204, headers: _corsHeaders);
  }

  if (request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      headers: _corsHeaders,
      body: const <String, dynamic>{
        'status': 'error',
        'error': 'Method not allowed.',
      },
    );
  }

  try {
    final dynamic decodedBody = await request.json();
    if (decodedBody is! Map) {
      throw const FormatException('Request body must be a JSON object.');
    }

    final body = Map<String, dynamic>.from(decodedBody);
    final imageBase64 = body['imageBase64']?.toString() ?? '';
    final rawSections = body['sections'];

    if (imageBase64.isEmpty) {
      throw const FormatException('imageBase64 is required.');
    }

    if (rawSections is! List) {
      throw const FormatException('sections must be a JSON array.');
    }

    final imageBytes = base64Decode(imageBase64);
    final sections = rawSections
        .whereType<Map>()
        .map((section) => Map<String, dynamic>.from(section))
        .toList();

    final result = ServerOpenCVOMRProcessor.process(
      imageBytes,
      sections: sections,
    );

    return Response.json(
      headers: _corsHeaders,
      body: <String, dynamic>{
        'status': 'ok',
        'result': result.toJson(),
      },
    );
  } on FormatException catch (e) {
    return Response.json(
      statusCode: 400,
      headers: _corsHeaders,
      body: <String, dynamic>{
        'status': 'error',
        'error': e.message,
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      headers: _corsHeaders,
      body: <String, dynamic>{
        'status': 'error',
        'error': 'OMR processing failed: $e',
      },
    );
  }
}
