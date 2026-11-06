/// Client-side minimum question validation and header metadata helpers for
/// CheckMate assessments. Mirrors `server/lib/exams/exam_validator.dart` so
/// Flutter and Dart Frog enforce identical rules.
class QuestionTypeValidation {
  const QuestionTypeValidation({
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
}

class AssessmentValidationResult {
  const AssessmentValidationResult({
    required this.assessmentType,
    required this.assessmentLabel,
    required this.requiredTotal,
    required this.actualTotal,
    required this.requiredPerQuestionType,
    required this.questionTypeValidations,
    required this.errors,
    this.missingAnswerKeyCount = 0,
  });

  final String assessmentType;
  final String assessmentLabel;
  final int requiredTotal;
  final int actualTotal;
  final int requiredPerQuestionType;
  final List<QuestionTypeValidation> questionTypeValidations;
  final List<String> errors;
  final int missingAnswerKeyCount;

  bool get isValid => errors.isEmpty;

  int get missingTotal =>
      actualTotal >= requiredTotal ? 0 : requiredTotal - actualTotal;

  List<QuestionTypeValidation> get invalidQuestionTypes =>
      questionTypeValidations.where((q) => !q.isValid).toList();

  String get summaryMessage {
    if (isValid) {
      return '$assessmentLabel meets all minimum requirements '
          '($actualTotal/$requiredTotal total questions).';
    }
    return errors.join(' ');
  }
}

/// Structured header metadata for Major Examinations (`Prelim`, `Midterm`,
/// `Prefinals`, `Finals`), encoded cleanly into `exams.description` (and also
/// readable from direct map keys if present).
class ExamHeaderDetails {
  const ExamHeaderDetails({
    this.examDay = '',
    this.examDate = '',
    this.startTime = '',
    this.endTime = '',
    this.referenceNo = '',
  });

  final String examDay;
  final String examDate;
  final String startTime;
  final String endTime;
  final String referenceNo;

  /// Formats `Day <examDay> – <examDate>` (e.g. `"Day 1 – April 4, 2026"`).
  String get scheduleDateLine {
    final d = examDay.trim();
    final dt = examDate.trim();
    final dayPart = d.isEmpty
        ? ''
        : (d.toLowerCase().startsWith('day') ? d : 'Day $d');
    if (dayPart.isNotEmpty && dt.isNotEmpty) {
      return '$dayPart \u2013 $dt';
    }
    if (dayPart.isNotEmpty) return dayPart;
    return dt;
  }

  /// Formats `<startTime> – <endTime>` (e.g. `"8:00 AM – 9:15 AM"`).
  String get scheduleTimeLine {
    final s = startTime.trim();
    final e = endTime.trim();
    if (s.isNotEmpty && e.isNotEmpty) {
      return '$s \u2013 $e';
    }
    if (s.isNotEmpty) return s;
    return e;
  }

  /// Encodes the header details into a human-readable multi-line string stored
  /// in `exams.description`.
  String toDescriptionString() {
    final lines = <String>[];
    final dateLine = scheduleDateLine;
    final timeLine = scheduleTimeLine;
    final ref = referenceNo.trim();

    if (dateLine.isNotEmpty) lines.add(dateLine);
    if (timeLine.isNotEmpty) lines.add(timeLine);
    if (ref.isNotEmpty) lines.add('Ref: $ref');
    return lines.join('\n');
  }

  /// Summary string for displaying under the Exam Builder title area.
  List<String> get builderMetadataParts {
    final parts = <String>[];
    if (scheduleDateLine.isNotEmpty) parts.add(scheduleDateLine);
    if (scheduleTimeLine.isNotEmpty) parts.add(scheduleTimeLine);
    if (referenceNo.trim().isNotEmpty) {
      parts.add('Ref: ${referenceNo.trim()}');
    }
    return parts;
  }

  static ExamHeaderDetails fromExam(Map<String, dynamic>? exam) {
    if (exam == null) return const ExamHeaderDetails();

    String clean(Object? v) {
      final s = (v?.toString() ?? '').trim();
      return s.toLowerCase() == 'null' ? '' : s;
    }

    var day = clean(exam['exam_day']);
    var date = clean(exam['exam_date'] ?? exam['date']);
    var start = clean(exam['start_time']);
    var end = clean(exam['end_time']);
    var ref = clean(
      exam['reference_no'] ?? exam['course_code'] ?? exam['course_id'],
    );

    final rawTime = clean(exam['exam_time'] ?? exam['schedule']);
    if (rawTime.isNotEmpty && start.isEmpty && end.isEmpty) {
      final timeParts = rawTime.split(RegExp(r'\s*[\u2013\u2014\-]\s*'));
      if (timeParts.length >= 2) {
        start = timeParts.first.trim();
        end = timeParts.sublist(1).join(' \u2013 ').trim();
      } else {
        start = rawTime;
      }
    }

    final rawDesc = clean(exam['description']);
    if (rawDesc.isNotEmpty) {
      final lines = rawDesc
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      for (final line in lines) {
        final lower = line.toLowerCase();
        if (lower == 'prelim' ||
            lower == 'midterm' ||
            lower == 'prefinal' ||
            lower == 'pre-finals' ||
            lower == 'final' ||
            lower == 'finals' ||
            lower == 'quiz' ||
            lower == 'short quiz' ||
            lower == 'long quiz' ||
            lower == 'other' ||
            lower == 'preliminary examination' ||
            lower == 'midterm examination' ||
            lower == 'pre-final examination' ||
            lower == 'final examination') {
          continue;
        }

        if (lower.startsWith('ref:') ||
            lower.startsWith('reference:') ||
            lower.startsWith('reference no.:') ||
            lower.startsWith('reference no:')) {
          final colonIdx = line.indexOf(':');
          if (colonIdx >= 0 && ref.isEmpty) {
            ref = line.substring(colonIdx + 1).trim();
          }
          continue;
        }

        final dayAndDateMatch = RegExp(
          r'^day\s*(\d+)\s*[:\u2013\u2014\-]\s*(.+)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (dayAndDateMatch != null) {
          if (day.isEmpty) day = dayAndDateMatch.group(1)!.trim();
          if (date.isEmpty) date = dayAndDateMatch.group(2)!.trim();
          continue;
        }

        final dayOnlyMatch = RegExp(
          r'^day\s*(\d+)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (dayOnlyMatch != null) {
          if (day.isEmpty) day = dayOnlyMatch.group(1)!.trim();
          continue;
        }

        if (RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(line) ||
            RegExp(r'\b(am|pm)\b', caseSensitive: false).hasMatch(line)) {
          if (start.isEmpty && end.isEmpty) {
            final tParts = line.split(RegExp(r'\s*[\u2013\u2014\-]\s*'));
            if (tParts.length >= 2) {
              start = tParts.first.trim();
              end = tParts.sublist(1).join(' \u2013 ').trim();
            } else {
              start = line;
            }
          }
          continue;
        }

        if (date.isEmpty &&
            (RegExp(r'\b\d{4}\b').hasMatch(line) ||
                RegExp(
                  r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)',
                  caseSensitive: false,
                ).hasMatch(line))) {
          date = line;
          continue;
        }

        if (ref.isEmpty &&
            RegExp(r'\d{5,}\s*[\u2013\u2014\-]').hasMatch(line)) {
          ref = line;
        }
      }
    }

    return ExamHeaderDetails(
      examDay: day,
      examDate: date,
      startTime: start,
      endTime: end,
      referenceNo: ref,
    );
  }
}

class AssessmentValidator {
  AssessmentValidator._();

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

  static const Map<String, String> assessmentTypeLabels = <String, String>{
    'quiz': 'Quiz',
    'short_quiz': 'Short Quiz',
    'long_quiz': 'Long Quiz',
    'prelim': 'Prelim',
    'midterm': 'Midterm',
    'prefinal': 'Prefinals',
    'final': 'Finals',
    'other': 'Other',
  };

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

  static bool isMajorExamination(
    String? rawType, {
    String? title,
    String? description,
  }) {
    final normalized = normalizeAssessmentType(
      rawType,
      title: title,
      description: description,
    );
    return normalized == 'prelim' ||
        normalized == 'midterm' ||
        normalized == 'prefinal' ||
        normalized == 'pre_finals' ||
        normalized == 'final' ||
        normalized == 'finals';
  }

  static String assessmentTypeLabel(
    String? rawType, {
    String? title,
    String? description,
  }) {
    final normalized = normalizeAssessmentType(
      rawType,
      title: title,
      description: description,
    );
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

  static String formalExaminationTitle(
    String? rawType, {
    String? title,
    String? description,
  }) {
    final normalized = normalizeAssessmentType(
      rawType,
      title: title,
      description: description,
    );
    switch (normalized) {
      case 'prelim':
        return 'Preliminary Examination';
      case 'midterm':
        return 'Midterm Examination';
      case 'prefinal':
      case 'pre_finals':
        return 'Pre-Final Examination';
      case 'final':
      case 'finals':
        return 'Final Examination';
      case 'long_quiz':
        return (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Long Quiz';
      case 'short_quiz':
        return (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Short Quiz';
      case 'other':
        return (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Assessment';
      case 'quiz':
      default:
        return (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Quiz';
    }
  }

  /// Formats a school year string consistently (e.g. `"SY 2026-2027"`).
  static String formatSchoolYear(Object? rawSchoolYear) {
    final clean = (rawSchoolYear?.toString() ?? '').trim();
    if (clean.isEmpty || clean.toLowerCase() == 'null') {
      final now = DateTime.now();
      final startYear = now.month >= 6 ? now.year : now.year - 1;
      return 'SY $startYear-${startYear + 1}';
    }
    return clean.toUpperCase().startsWith('SY') ? clean : 'SY $clean';
  }

  /// Formats a school term / semester string consistently (e.g. `"1st Term"` or `"2nd Term"`).
  static String formatSchoolTerm(Object? rawSemester) {
    final clean = (rawSemester?.toString() ?? '').trim();
    if (clean.isEmpty || clean.toLowerCase() == 'null') {
      return '1st Term';
    }
    final lower = clean.toLowerCase();
    if (lower.startsWith('1') || lower.contains('first')) {
      return '1st Term';
    }
    if (lower.startsWith('2') || lower.contains('second')) {
      return '2nd Term';
    }
    if (lower.startsWith('3') || lower.contains('third')) {
      return '3rd Term';
    }
    return clean;
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

  static AssessmentValidationResult validate({
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
      description: description,
    );
    final requiredTotal = requiredTotalQuestions(
      normalizedAssessment,
      title: title,
      description: description,
    );

    final includedOrder = <String>[];
    final countsByType = <String, int>{};
    var missingAnswerKeyCount = 0;

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
        final qList = questionsBySectionId[sectionId]!;
        count = qList.length;
        for (final q in qList) {
          final ans = (q['correct_answer']?.toString() ?? '').trim();
          if (ans.isEmpty || ans.toLowerCase() == 'null') {
            missingAnswerKeyCount++;
          }
        }
      } else if (section['questions'] is List) {
        final qList = section['questions'] as List;
        count = qList.length;
        for (final q in qList.whereType<Map>()) {
          final ans = (q['correct_answer']?.toString() ?? '').trim();
          if (ans.isEmpty || ans.toLowerCase() == 'null') {
            missingAnswerKeyCount++;
          }
        }
      } else if (section['question_count'] != null) {
        count = int.tryParse(section['question_count'].toString()) ?? 0;
      }

      countsByType[qType] = (countsByType[qType] ?? 0) + count;
    }

    final actualTotal = countsByType.values.fold<int>(
      0,
      (sum, item) => sum + item,
    );

    final typeValidations = <QuestionTypeValidation>[];
    final errors = <String>[];

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
        final v = QuestionTypeValidation(
          questionType: qType,
          label: label,
          requiredCount: minQuestionsPerIncludedType,
          actualCount: actual,
        );
        typeValidations.add(v);

        if (!v.isValid) {
          errors.add(
            '$label requires at least $minQuestionsPerIncludedType questions '
            '(currently has $actual; add ${v.missingCount} more).',
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

      if (missingAnswerKeyCount > 0) {
        errors.add(
          '$missingAnswerKeyCount ${missingAnswerKeyCount == 1 ? 'question is' : 'questions are'} '
          'missing an answer key. Select the correct answer for each question below.',
        );
      }
    }

    return AssessmentValidationResult(
      assessmentType: normalizedAssessment,
      assessmentLabel: assessmentLabel,
      requiredTotal: requiredTotal,
      actualTotal: actualTotal,
      requiredPerQuestionType: minQuestionsPerIncludedType,
      questionTypeValidations: typeValidations,
      errors: errors,
      missingAnswerKeyCount: missingAnswerKeyCount,
    );
  }
}
