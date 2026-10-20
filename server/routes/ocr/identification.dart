import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:http/http.dart' as http;

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405, body: 'Method not allowed');
  }

  final endpoint = Platform.environment['AZURE_VISION_ENDPOINT'];
  final key = Platform.environment['AZURE_VISION_KEY'];
  if (endpoint == null || endpoint.isEmpty || key == null || key.isEmpty) {
    return Response.json(statusCode: 503, body: {'error': 'Azure Vision is not configured'});
  }

  try {
    final payload = await context.request.json() as Map<String, dynamic>;
    final imageBase64 = payload['image_base64'];
    if (imageBase64 is! String || imageBase64.isEmpty) {
      return Response.json(statusCode: 400, body: {'error': 'image_base64 is required'});
    }
    final bytes = base64Decode(imageBase64);
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      return Response.json(statusCode: 400, body: {'error': 'Image must be 1 byte to 4 MB'});
    }

    final root = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    final url = Uri.parse('$root/vision/v3.2/read/analyze');
    final client = http.Client();
    try {
      final submitted = await client.post(
        url,
        headers: {
          'Ocp-Apim-Subscription-Key': key,
          'Content-Type': 'application/octet-stream',
        },
        body: bytes,
      ).timeout(const Duration(seconds: 30));

      if (submitted.statusCode != 202) {
        return Response.json(statusCode: 502, body: {
          'error': 'Azure did not accept the image',
          'azure_status': submitted.statusCode,
          'details': submitted.body.length > 500 ? submitted.body.substring(0, 500) : submitted.body,
        });
      }
      final operation = submitted.headers['operation-location'];
      if (operation == null || operation.isEmpty) {
        return Response.json(statusCode: 502, body: {'error': 'Azure returned no operation location'});
      }
      final operationUri = Uri.parse(operation);
      if (operationUri.scheme != 'https' || operationUri.host != url.host) {
        return Response.json(statusCode: 502, body: {'error': 'Unexpected Azure operation URL'});
      }

      for (var attempt = 0; attempt < 15; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final result = await client.get(operationUri, headers: {
          'Ocp-Apim-Subscription-Key': key,
        }).timeout(const Duration(seconds: 20));
        if (result.statusCode != 200) {
          return Response.json(statusCode: 502, body: {'error': 'Could not retrieve Azure OCR result', 'azure_status': result.statusCode});
        }
        final data = jsonDecode(result.body) as Map<String, dynamic>;
        final status = data['status']?.toString().toLowerCase();
        if (status == 'failed') {
          return Response.json(statusCode: 502, body: {'error': 'Azure OCR failed'});
        }
        if (status == 'succeeded') {
          final analyze = data['analyzeResult'] as Map<String, dynamic>?;
          final pages = analyze?['readResults'] as List<dynamic>? ?? [];
          final lines = <String>[];
          for (final page in pages) {
            if (page is! Map<String, dynamic>) continue;
            for (final line in (page['lines'] as List<dynamic>? ?? [])) {
              if (line is Map<String, dynamic> && line['text'] is String) {
                lines.add(line['text'] as String);
              }
            }
          }
          return Response.json(body: {
            'recognized_text': lines.join(' ').trim(),
            'requires_verification': true,
          });
        }
      }
      return Response.json(statusCode: 504, body: {'error': 'Azure OCR timed out; try again'});
    } finally {
      client.close();
    }
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'Invalid base64 image'});
  } catch (_) {
    return Response.json(statusCode: 500, body: {'error': 'OCR processing failed'});
  }
}
