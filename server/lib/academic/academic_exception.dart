/// Represents an error encountered during academic management operations.
class AcademicException implements Exception {
  /// Creates an academic error with an HTTP status code and optional issues.
  AcademicException(
    this.message, {
    this.statusCode = 400,
    this.issues = const [],
  });

  /// The error message shown to the client.
  final String message;

  /// The HTTP status code associated with the error.
  final int statusCode;

  /// Extra detail lines (used by publish validation).
  final List<String> issues;

  /// Extra detail lines (used by publish validation).
  @override
  String toString() => message;
}
