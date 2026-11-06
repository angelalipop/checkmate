/// Server-side minimum question validation for CheckMate assessments.
class ExamQuestionTypeRequirement {
  const ExamQuestionTypeRequirement({
    required this.questionType,
    required this.label,
    required this.requiredCount,
    required this.actualCount,
  });

  final String questionType;
  final String label;
  final int requiredCount;
  final int actualCount;

  bool get isValid => actualCount >= requiredCount;

  int get missingCount =>
      actualCount >= requiredCount ? 0 : requiredCount - actualCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'question_type': questionType,
        'label': label,
        'required': requiredCount,
        'actual': actualCount,
        'missing': missingCount,
        'is_valid': isValid,
      };
}

class ExamValidationResult {
  const ExamValidationResult({
    required this.assessmentType,
    required this.assessmentLabel,
    required this.requiredTotal,
    required this.actualTotal,
    required this.requiredPerQuestionType,
    required this.questionTypeRequirements,
    required this.errors,
  });

  final String assessmentType;
  final String assessmentLabel;
  final int requiredTotal;
  final int actualTotal;
  final int requiredPerQuestionType;
  final List<ExamQuestionTypeRequirement> questionTypeRequirements;
  final List<String> errors;

  bool get isValid => errors.isEmpty;

  int get missingTotal =>
      actualTotal >= requiredTotal ? 0 : requiredTotal - actualTotal;

  String get summaryMessage {
    if (isValid) {
      return '$assessmentLabel meets all minimum question requirements '
          '($actualTotal/$requiredTotal total questions).';
    }
    return errors.join(' ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'is_valid': isValid,
        'assessment_type': assessmentType,
        'assessment_label': assessmentLabel,
        'required_total': requiredTotal,
        'actual_total': actualTotal,
        'missing_total': missingTotal,
        'required_per_question_type': requiredPerQuestionType,
        'question_types':
            questionTypeRequirements.map((r) => r.toJson()).toList(),
        'errors': errors,
        'message': summaryMessage,
      };
}

class ExamValidator {
  ExamValidator._();

  static const int minQuestionsPerIncludedType = 5;

  static const Map<String, int> minTotalByAssessmentType = <String, int>{
    'quiz': 5,
    'short_quiz': 5,
    'long_quiz': 15,
    'prelim': 35,
    'midterm': 35,
    'prefinal': 35,
    'pre_finals': 35,
    'final': 35,
    'finals': 35,
    'other': 5,
  };

  static const Set<String> supportedQuestionTypes = <String>{
    'identification',
    'multiple_choice',
    'true_false',
  };

  /// Normalizes an assessment type string or infers it from title/description
  /// when legacy records have a null assessment_type.
  static String normalizeAssessmentType(
    String? rawType, {
    String? title,
    String? description,
  }) {
    final cleaned = (rawType ?? '')
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(RegExp(r'\s+'), '_');

    switch (cleaned) {
      case 'quiz':
        return 'quiz';
      case 'short_quiz':
      case 'shortquiz':
        return 'short_quiz';
      case 'long_quiz':
      case 'longquiz':
        return 'long_quiz';
      case 'prelim':
      case 'prelims':
      case 'preliminary':
      case 'preliminary_exam':
      case 'preliminary_examination':
        return 'prelim';
      case 'midterm':
      case 'midterms':
      case 'midterm_exam':
      case 'midterm_examination':
        return 'midterm';
      case 'prefinal':
      case 'prefinals':
      case 'pre_final':
      case 'pre_finals':
      case 'pre_final_exam':
      case 'pre_final_examination':
        return 'prefinal';
      case 'final':
      case 'finals':
      case 'final_exam':
      case 'final_examination':
        return 'final';
      case 'other':
        return 'other';
    }

    final combined = '${title ?? ''} ${description ?? ''}'.toLowerCase();
    if (combined.contains('long quiz')) return 'long_quiz';
    if (combined.contains('short quiz')) return 'short_quiz';
    if (combined.contains('pre-final') || combined.contains('prefinal')) {
      return 'prefinal';
    }
    if (combined.contains('prelim')) return 'prelim';
    if (combined.contains('midterm')) return 'midterm';
    if (combined.contains('final')) return 'final';
    if (combined.contains('quiz')) return 'quiz';

    return cleaned.isEmpty ? 'quiz' : cleaned;
  }

  static bool isValidAssessmentType(String? rawType) {
    if (rawType == null || rawType.trim().isEmpty) return false;
    final normalized = normalizeAssessmentType(rawType);
    return minTotalByAssessmentType.containsKey(normalized);
  }

  /// Maps normalized assessment type to the database column value stored in
  /// `exams.assessment_type` (compatible with 004_my_subjects.sql and 005).
  static String toDatabaseAssessmentType(String rawType) {
    final normalized = normalizeAssessmentType(rawType);
    switch (normalized) {
      case 'pre_finals':
        return 'prefinal';
      case 'finals':
        return 'final';
      default:
        return normalized;
    }
  }

  static String assessmentTypeLabel(String? rawType, {String? title}) {
    final normalized = normalizeAssessmentType(rawType, title: title);
    switch (normalized) {
      case 'quiz':
        return 'Quiz';
      case 'short_quiz':
        return 'Short Quiz';
      case 'long_quiz':
        return 'Long Quiz';
      case 'prelim':
        return 'Prelim';
      case 'midterm':
        return 'Midterm';
      case 'prefinal':
      case 'pre_finals':
        return 'Pre-Finals';
      case 'final':
      case 'finals':
        return 'Finals';
      case 'other':
        return 'Other';
      default:
        return 'Assessment';
    }
  }

  static int requiredTotalQuestions(
    String? rawType, {
    String? title,
    String? description,
  }) {
    final normalized = normalizeAssessmentType(
      rawType,
      title: title,
      description: description,
    );
    return minTotalByAssessmentType[normalized] ?? 5;
  }

  static String normalizeQuestionType(String? rawType) {
    final cleaned = (rawType ?? '')
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(RegExp(r'\s+'), '_');
    switch (cleaned) {
      case 'identification':
      case 'identify':
        return 'identification';
      case 'multiple_choice':
      case 'multiplechoice':
      case 'mc':
      case 'mcq':
        return 'multiple_choice';
      case 'true_false':
      case 'true_or_false':
      case 'truefalse':
      case 'tf':
        return 'true_false';
      default:
        return cleaned;
    }
  }

  static String questionTypeLabel(String rawType) {
    switch (normalizeQuestionType(rawType)) {
      case 'identification':
        return 'Identification';
      case 'multiple_choice':
        return 'Multiple Choice';
      case 'true_false':
        return 'True or False';
      default:
        return rawType;
    }
  }

  /// Validates an assessment given its sections and question counts.
  ///
  /// Each entry in [sections] may contain:
  /// - `question_type`: String
  /// - `question_count`: int (or `questions`: List)
  static ExamValidationResult validate({
    required String? assessmentType,
    String? title,
    String? description,
    required List<Map<String, dynamic>> sections,
    Map<int, List<Map<String, dynamic>>>? questionsBySectionId,
  }) {
    final normalizedAssessment = normalizeAssessmentType(
      assessmentType,
      title: title,
      description: description,
    );
    final assessmentLabel = assessmentTypeLabel(
      normalizedAssessment,
      title: title,
    );
    final requiredTotal = requiredTotalQuestions(
      normalizedAssessment,
      title: title,
      description: description,
    );

    final errors = <String>[];
    if (assessmentType != null &&
        assessmentType.trim().isNotEmpty &&
        !minTotalByAssessmentType.containsKey(normalizedAssessment)) {
      errors.add('Invalid assessment type "$assessmentType".');
    }

    // Track included question types and their total question counts.
    // A question type is included whenever at least one section of that type
    // exists in the assessment OR questions of that type exist.
    final includedOrder = <String>[];
    final countsByType = <String, int>{};

    for (final section in sections) {
      final qType = normalizeQuestionType(
        section['question_type']?.toString() ?? section['type']?.toString(),
      );
      if (qType.isEmpty) continue;

      if (!includedOrder.contains(qType)) {
        includedOrder.add(qType);
      }

      var count = 0;
      final sectionId = int.tryParse(section['id']?.toString() ?? '');
      if (questionsBySectionId != null &&
          sectionId != null &&
          questionsBySectionId.containsKey(sectionId)) {
        count = questionsBySectionId[sectionId]!.length;
      } else if (section['questions'] is List) {
        count = (section['questions'] as List).length;
      } else if (section['question_count'] != null) {
        count = int.tryParse(section['question_count'].toString()) ?? 0;
      }

      countsByType[qType] = (countsByType[qType] ?? 0) + count;
    }

    final actualTotal =
        countsByType.values.fold<int>(0, (sum, item) => sum + item);

    final typeRequirements = <ExamQuestionTypeRequirement>[];

    if (includedOrder.isEmpty) {
      errors.add(
        '$assessmentLabel requires at least $requiredTotal total questions '
        '(currently 0). Add at least one question section with a minimum of '
        '$minQuestionsPerIncludedType questions.',
      );
    } else {
      for (final qType in includedOrder) {
        final actual = countsByType[qType] ?? 0;
        final label = questionTypeLabel(qType);
        final req = ExamQuestionTypeRequirement(
          questionType: qType,
          label: label,
          requiredCount: minQuestionsPerIncludedType,
          actualCount: actual,
        );
        typeRequirements.add(req);

        if (!req.isValid) {
          errors.add(
            '$label requires at least $minQuestionsPerIncludedType questions '
            '(currently has $actual; add ${req.missingCount} more).',
          );
        }
      }

      if (actualTotal < requiredTotal) {
        final missing = requiredTotal - actualTotal;
        errors.add(
          '$assessmentLabel requires at least $requiredTotal total questions '
          'across all question types (currently has $actualTotal; add '
          '$missing more).',
        );
      }
    }

    return ExamValidationResult(
      assessmentType: normalizedAssessment,
      assessmentLabel: assessmentLabel,
      requiredTotal: requiredTotal,
      actualTotal: actualTotal,
      requiredPerQuestionType: minQuestionsPerIncludedType,
      questionTypeRequirements: typeRequirements,
      errors: errors,
    );
  }
}
