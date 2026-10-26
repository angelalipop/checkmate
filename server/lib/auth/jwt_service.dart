import 'dart:io';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// A service for generating and verifying JWT tokens.
class JwtService {
  static String get _secret {
    final secret = Platform.environment['JWT_SECRET'];

    if (secret == null || secret.trim().isEmpty) {
      throw StateError('JWT_SECRET is not configured.');
    }

    return secret;
  }

/// Generates a JWT token for the given user information.
  static String generateToken({
    required int userId,
    required String email,
    required String role,
  }) {
    final jwt = JWT(
      {
        'userId': userId,
        'email': email,
        'role': role,
      },
      issuer: 'checkmate',
    );

    return jwt.sign(
      SecretKey(_secret),
      expiresIn: const Duration(hours: 24),
    );
  }

/// Verifies the given JWT token and returns the payload as a map.
  static Map<String, dynamic> verifyToken(String token) {
    final jwt = JWT.verify(
      token,
      SecretKey(_secret),
      issuer: 'checkmate',
    );

    return Map<String, dynamic>.from(jwt.payload as Map);
  }
}
