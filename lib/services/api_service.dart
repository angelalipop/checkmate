import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'http://localhost:8080';

  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw Exception(data['message'] ?? 'Login failed');
    }

    return data;
  }
}
