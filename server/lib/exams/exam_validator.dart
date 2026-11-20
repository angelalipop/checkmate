/// Per-format item counts included in an assessment's validation response.
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
    this.itemCountWarnings = const [],
  });

  final String assessmentType;
  final String assessmentLabel;
  final int requiredTotal;
  final int actualTotal;
  final int requiredPerQuestionType;
  final List<ExamQuestionTypeRequirement> questionTypeRequirements;
  final List<String> errors;
  final List<String> itemCountWarnings;

  bool get isValid => errors.isEmpty;

  int get missingTotal =>
      actualTotal >= requiredTotal ? 0 : requiredTotal - actualTotal;

  String get summaryMessage {
    if (isValid) {
      return '$assessmentLabel meets the publishing requirements.';
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
        'item_count_warnings': itemCountWarnings,
        'message': summaryMessage,
      };
}

class ExamValidator {
  ExamValidator._();

  static const int minQuestionsPerIncludedType = 0;
  static const int _minQuestionsToPublish = 1;

  static const Map<String, int> minTotalByAssessmentType = <String, int>{
    'quiz': _minQuestionsToPublish,
    'short_quiz': _minQuestionsToPublish,
    'long_quiz': _minQuestionsToPublish,
    'performance_task': _minQuestionsToPublish,
    'laboratory': _minQuestionsToPublish,
    'prelim': _minQuestionsToPublish,
    'midterm': _minQuestionsToPublish,
    'prefinal': _minQuestionsToPublish,
    'pre_finals': _minQuestionsToPublish,
    'final': _minQuestionsToPublish,
    'finals': _minQuestionsToPublish,
    'other': _minQuestionsToPublish,
  };

  static const Map<String, int> _recommendedTotalByAssessmentType = {
    'long_quiz': 15,
    'prelim': 35,
    'midterm': 35,
    'prefinal': 35,
    'final': 35,
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
      case 'performance_task':
        return 'performance_task';
      case 'laboratory':
        return 'laboratory';
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
      case 'performance_task':
        return 'Performance Task';
      case 'laboratory':
        return 'Laboratory';
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
    return minTotalByAssessmentType[normalized] ?? _minQuestionsToPublish;
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

  /// Checks publish eligibility and returns item-count guidance.
  /// Each section can supply its questions or precomputed question and
  /// missing-answer-key counts from the database.
  static ExamValidationResult validate({
    required String? assessmentType,
    required List<Map<String, dynamic>> sections,
    String? title,
    String? description,
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

    final recommendedTotal =
        _recommendedTotalByAssessmentType[normalizedAssessment];
    final errors = <String>[];
    final itemCountWarnings = <String>[];
    if (assessmentType != null &&
        assessmentType.trim().isNotEmpty &&
        !minTotalByAssessmentType.containsKey(normalizedAssessment)) {
      errors.add('Invalid assessment type "$assessmentType".');
    }

    final countsByType = <String, int>{};
    var actualTotal = 0;
    var missingAnswerKeyCount = 0;

    for (final section in sections) {
      final qType = normalizeQuestionType(
        section['question_type']?.toString() ?? section['type']?.toString(),
      );
      final sectionId = int.tryParse(section['id']?.toString() ?? '');
      final questions =
          questionsBySectionId?[sectionId] ?? section['questions'];
      final count = questions is List
          ? questions.length
          : int.tryParse(section['question_count']?.toString() ?? '') ?? 0;
      if (questions is List) {
        for (final question in questions.whereType<Map>()) {
          final answer = question['correct_answer']
              ?.toString()
              .trim()
              .toLowerCase();
          if (answer == null || answer.isEmpty || answer == 'null') {
            missingAnswerKeyCount++;
          }
        }
      } else {
        missingAnswerKeyCount +=
            int.tryParse(
              section['missing_answer_key_count']?.toString() ?? '',
            ) ??
            0;
      }

      actualTotal += count;
      if (qType.isNotEmpty) {
        countsByType[qType] = (countsByType[qType] ?? 0) + count;
      }
    }

    if (recommendedTotal != null && actualTotal < recommendedTotal) {
      itemCountWarnings.add(
        '$assessmentLabel has $actualTotal saved ${actualTotal == 1 ? 'item' : 'items'}. '
        'Aim for at least $recommendedTotal in total.',
      );
    }
    if (actualTotal < requiredTotal) {
      errors.add('Add at least one item before publishing.');
    }
    if (missingAnswerKeyCount > 0) {
      errors.add(
        '$missingAnswerKeyCount ${missingAnswerKeyCount == 1 ? 'item is' : 'items are'} '
        'missing an answer key. Select the correct answer for each item.',
      );
    }

    return ExamValidationResult(
      assessmentType: normalizedAssessment,
      assessmentLabel: assessmentLabel,
      requiredTotal: requiredTotal,
      actualTotal: actualTotal,
      requiredPerQuestionType: minQuestionsPerIncludedType,
      questionTypeRequirements: [
        for (final entry in countsByType.entries)
          ExamQuestionTypeRequirement(
            questionType: entry.key,
            label: questionTypeLabel(entry.key),
            requiredCount: minQuestionsPerIncludedType,
            actualCount: entry.value,
          ),
      ],
      errors: errors,
      itemCountWarnings: itemCountWarnings,
    );
  }
}
