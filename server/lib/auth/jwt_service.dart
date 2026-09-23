import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class JwtService {
  static const _secret = String.fromEnvironment(
    'JWT_SECRET',
    defaultValue: 'checkmate-dev-jwt-secret-change-this',
  );

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

  static Map<String, dynamic> verifyToken(String token) {
    final jwt = JWT.verify(
      token,
      SecretKey(_secret),
      issuer: 'checkmate',
    );

    return Map<String, dynamic>.from(jwt.payload as Map);
  }
}
