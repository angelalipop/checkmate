import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Client for the /sections endpoints (section catalog).
class SectionApi {
  static Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  static Map<String, dynamic> _decode(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception(
          'The server sent an unexpected response (${r.statusCode}).');
    }
  }

  static Future<List<Map<String, dynamic>>> getSections(String token) async {
    final response = await http.get(
      Uri.parse('${ApiService.baseUrl}/sections'),
      headers: _headers(token),
    );
    final data = _decode(response);
    if (response.statusCode != 200) {
      throw Exception(data['message'] ?? 'Failed to load sections');
    }
    final list = data['sections'];
    if (list is! List) throw Exception('Invalid sections data received.');
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<Map<String, dynamic>> createSection(
    String token, {
    required int programId,
    required String name,
    required int yearLevel,
    required String schoolYear,
    required int semester,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiService.baseUrl}/sections'),
      headers: _headers(token),
      body: jsonEncode({
        'program_id': programId,
        'name': name,
        'year_level': yearLevel,
        'school_year': schoolYear,
        'semester': semester,
      }),
    );
    final data = _decode(response);
    if (response.statusCode != 201) {
      throw Exception(data['message'] ?? 'Failed to create section');
    }
    return Map<String, dynamic>.from(data['section'] as Map);
  }
}
