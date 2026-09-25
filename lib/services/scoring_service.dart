import '../services/omr_processor.dart';

class ScoredAnswer {
  final int questionNumber;
  final String studentAnswer;
  final String correctAnswer;
  final double points;
  final double earnedPoints;
  final bool isCorrect;

  const ScoredAnswer({
    required this.questionNumber,
    required this.studentAnswer,
    required this.correctAnswer,
    required this.points,
    required this.earnedPoints,
    required this.isCorrect,
  });
}

class ScoredSection {
  final String sectionName;
  final String sectionType;
  final int questionCount;
  final double totalPoints;
  final double earnedPoints;
  final List<ScoredAnswer> answers;

  const ScoredSection({
    required this.sectionName,
    required this.sectionType,
    required this.questionCount,
    required this.totalPoints,
    required this.earnedPoints,
    required this.answers,
  });
}

class ScoringResult {
  final int totalQuestions;
  final int answeredQuestions;
  final int correctAnswers;
  final double totalPoints;
  final double earnedPoints;
  final double percentage;
  final List<ScoredSection> sections;

  const ScoringResult({
    required this.totalQuestions,
    required this.answeredQuestions,
    required this.correctAnswers,
    required this.totalPoints,
    required this.earnedPoints,
    required this.percentage,
    required this.sections,
  });
}

class ScoringService {
  static ScoringResult score({
    required OMRProcessingResult omrResult,
    required List<Map<String, dynamic>> sections,
  }) {
    final List<ScoredSection> scoredSections = [];

    int totalQuestions = 0;
    int answeredQuestions = 0;
    int correctAnswers = 0;

    double totalPoints = 0;
    double earnedPoints = 0;

    for (int sectionIndex = 0;
        sectionIndex < omrResult.sections.length;
        sectionIndex++) {
      final OMRSectionResult omrSection =
          omrResult.sections[sectionIndex];

      final Map<String, dynamic> sectionData =
          sectionIndex < sections.length
              ? sections[sectionIndex]
              : <String, dynamic>{};

      final dynamic rawQuestions =
          sectionData['questions'];

      final List<Map<String, dynamic>> questions =
          rawQuestions is List
              ? rawQuestions
                  .whereType<Map>()
                  .map(
                    (question) =>
                        Map<String, dynamic>.from(question),
                  )
                  .toList()
              : <Map<String, dynamic>>[];

      final List<ScoredAnswer> scoredAnswers = [];

      double sectionTotalPoints = 0;
      double sectionEarnedPoints = 0;

      for (final OMRAnswer studentAnswer
          in omrSection.answers) {
        final Map<String, dynamic>? question =
            _findQuestion(
          questions,
          studentAnswer.questionNumber,
        );

        if (question == null) {
          continue;
        }

        final String studentValue =
            _normalizeAnswer(studentAnswer.answer);

        final String correctValue =
            _normalizeAnswer(
          question['correct_answer']?.toString() ?? '',
        );

        final double points =
            _parsePoints(question['points']);

        final bool answered =
            studentValue.isNotEmpty &&
            studentValue != 'UNANSWERED' &&
            studentValue != 'OCR PENDING';

        final bool isCorrect =
            answered &&
            correctValue.isNotEmpty &&
            studentValue == correctValue;

        final double earned =
            isCorrect ? points : 0;

        if (answered) {
          answeredQuestions++;
        }

        if (isCorrect) {
          correctAnswers++;
        }

        totalQuestions++;
        totalPoints += points;
        earnedPoints += earned;

        sectionTotalPoints += points;
        sectionEarnedPoints += earned;

        scoredAnswers.add(
          ScoredAnswer(
            questionNumber:
                studentAnswer.questionNumber,
            studentAnswer:
                studentAnswer.answer,
            correctAnswer:
                question['correct_answer']?.toString() ??
                    '',
            points: points,
            earnedPoints: earned,
            isCorrect: isCorrect,
          ),
        );
      }

      scoredSections.add(
        ScoredSection(
          sectionName: omrSection.sectionName,
          sectionType: omrSection.sectionType,
          questionCount: omrSection.questionCount,
          totalPoints: sectionTotalPoints,
          earnedPoints: sectionEarnedPoints,
          answers: scoredAnswers,
        ),
      );
    }

    final double percentage =
        totalPoints > 0
            ? (earnedPoints / totalPoints) * 100
            : 0;

    return ScoringResult(
      totalQuestions: totalQuestions,
      answeredQuestions: answeredQuestions,
      correctAnswers: correctAnswers,
      totalPoints: totalPoints,
      earnedPoints: earnedPoints,
      percentage: percentage,
      sections: scoredSections,
    );
  }

  static Map<String, dynamic>? _findQuestion(
    List<Map<String, dynamic>> questions,
    int questionNumber,
  ) {
    for (final question in questions) {
      final int? number = int.tryParse(
        question['question_number']?.toString() ?? '',
      );

      if (number == questionNumber) {
        return question;
      }
    }

    return null;
  }

  static double _parsePoints(dynamic value) {
    if (value == null) {
      return 1;
    }

    return double.tryParse(
          value.toString(),
        ) ??
        1;
  }

  static String _normalizeAnswer(String value) {
    return value
        .trim()
        .toUpperCase()
        .replaceAll('TRUE', 'T')
        .replaceAll('FALSE', 'F');
  }
}
