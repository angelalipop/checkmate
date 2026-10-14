class AcademicException implements Exception {
  AcademicException(
    this.message, {
    this.statusCode = 400,
    this.issues = const [],
  });

  final String message;
  final int statusCode;

  /// Extra detail lines (used by publish validation).
  final List<String> issues;

  @override
  String toString() => message;
}
