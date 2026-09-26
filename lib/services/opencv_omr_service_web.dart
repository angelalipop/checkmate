import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

export 'opencv_omr_models.dart';
import 'opencv_omr_models.dart';

class OpenCVOMRService {
  static const String _defaultApiBaseUrl = 'http://localhost:8080';

  static String get apiBaseUrl => const String.fromEnvironment(
        'CHECKMATE_API_URL',
        defaultValue: _defaultApiBaseUrl,
      );

  static Future<OpenCVOMRResult> process(
    Uint8List correctedImageBytes, {
    required List<Map<String, dynamic>> sections,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/omr/process');

    http.Response response;
    try {
      response = await http.post(
        uri,
        headers: const <String, String>{
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'imageBase64': base64Encode(correctedImageBytes),
          'sections': sections,
        }),
      );
    } catch (e) {
      throw Exception(
        'Unable to reach the CheckMate OMR backend at $apiBaseUrl. '
        'Make sure Dart Frog is running. Details: $e',
      );
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      body = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    } catch (_) {
      throw Exception(
        'The OMR backend returned an invalid response '
        '(HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        body['error']?.toString() ??
            'OMR backend failed with HTTP ${response.statusCode}.',
      );
    }

    final rawResult = body['result'];
    if (rawResult is! Map) {
      throw Exception('The OMR backend response did not contain a result.');
    }

    return OpenCVOMRResult.fromJson(
      Map<String, dynamic>.from(rawResult),
    );
  }
}
