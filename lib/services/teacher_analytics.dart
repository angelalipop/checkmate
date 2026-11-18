/// Pure analytics calculations over stored examination attempts.
/// Question identity includes exam ID and question ID, never display number.
typedef AnalyticsJson = Map<String, dynamic>;

int? analyticsId(Object? value) => int.tryParse('${value ?? ''}');

class AnalyticsItem {
  AnalyticsItem(this.examId, this.examTitle, Map answer)
    : questionId = analyticsId(answer['question_id'])!,
      number = analyticsId(answer['question_number']) ?? 0,
      section = '${answer['section_name'] ?? 'Exam part'}',
      question = '${answer['question_text'] ?? ''}'.trim(),
      correctAnswer = '${answer['correct_answer'] ?? ''}'.trim();

  final int examId, questionId, number;
  final String examTitle, section, question, correctAnswer;
  int correct = 0, incorrect = 0, unanswered = 0;
  final Map<String, int> wrongAnswers = {};
  int get total => correct + incorrect;
  double get accuracy => total == 0 ? 0 : 100 * correct / total;
  double get missedRate => 100 - accuracy;
  String get difficulty => accuracy < 40
      ? 'Difficult'
      : accuracy < 80
      ? 'Moderate'
      : 'Easy';

  void add(Map answer) {
    if (answer['is_correct'] == true) {
      correct++;
      return;
    }
    incorrect++;
    final recognized = '${answer['recognized_answer'] ?? ''}'.trim();
    final raw = '${answer['raw_answer'] ?? ''}'.trim();
    var response = (recognized.isNotEmpty ? recognized : raw).toUpperCase();
    response = response.replaceAll(RegExp(r'\s+'), ' ');
    if (response.isEmpty ||
        const {
          'UNANSWERED',
          'BLANK',
          'AMBIGUOUS',
          'MULTIPLE',
          'OCR PENDING',
        }.contains(response)) {
      unanswered++;
    } else {
      wrongAnswers.update(response, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  List<MapEntry<String, int>> get commonWrongAnswers =>
      wrongAnswers.entries.toList()..sort((a, b) {
        final count = b.value.compareTo(a.value);
        return count == 0 ? a.key.compareTo(b.key) : count;
      });
}

class TeacherAnalyticsSummary {
  TeacherAnalyticsSummary._(this.percentages, this.items);
  final List<double> percentages;
  final List<AnalyticsItem> items;
  int get checked => percentages.length;
  double? get average =>
      checked == 0 ? null : percentages.reduce((a, b) => a + b) / checked;
  double? get highest =>
      checked == 0 ? null : percentages.reduce((a, b) => a > b ? a : b);
  double? get lowest =>
      checked == 0 ? null : percentages.reduce((a, b) => a < b ? a : b);
  int get difficult => items.where((i) => i.accuracy < 40).length;
  int get moderate =>
      items.where((i) => i.accuracy >= 40 && i.accuracy < 80).length;
  int get easy => items.where((i) => i.accuracy >= 80).length;
  List<AnalyticsItem> get missed =>
      items.where((i) => i.incorrect > 0).toList();
  Map<String, int> get buckets {
    final result = {'0–59': 0, '60–69': 0, '70–79': 0, '80–89': 0, '90–100': 0};
    for (final p in percentages) {
      final key = p < 60
          ? '0–59'
          : p < 70
          ? '60–69'
          : p < 80
          ? '70–79'
          : p < 90
          ? '80–89'
          : '90–100';
      result[key] = result[key]! + 1;
    }
    return result;
  }

  factory TeacherAnalyticsSummary.fromAttempts({
    required Map<int, String> examTitles,
    required Set<int> classIds,
    required Map<int, List<AnalyticsJson>> attemptsByExam,
  }) {
    final percentages = <double>[];
    final byQuestion = <String, AnalyticsItem>{};
    for (final exam in examTitles.entries) {
      // The attempts API is ordered most recently completed/created first.
      final seenStudents = <int>{};
      for (final attempt
          in attemptsByExam[exam.key] ?? const <AnalyticsJson>[]) {
        final student = attempt['student'];
        if (student is! Map) continue;
        final classId = analyticsId(student['class_id']);
        final studentId = analyticsId(attempt['student_id']);
        if (!classIds.contains(classId) ||
            studentId == null ||
            attempt['status'] != 'completed' ||
            !seenStudents.add(studentId)) {
          continue;
        }
        final answers = attempt['answers'];
        if (answers is! List ||
            answers.any(
              (a) => a is Map && a['verification_status'] == 'needs_review',
            ))
          continue;
        final score = double.tryParse('${attempt['score']}');
        final maximum = double.tryParse('${attempt['max_score']}');
        if (score == null ||
            maximum == null ||
            !score.isFinite ||
            !maximum.isFinite ||
            maximum <= 0)
          continue;
        percentages.add((100 * score / maximum).clamp(0.0, 100.0).toDouble());
        for (final answer in answers.whereType<Map>()) {
          if (answer['is_correct'] is! bool ||
              !(const {
                'automatic',
                'verified',
              }).contains(answer['verification_status']))
            continue;
          final qid = analyticsId(answer['question_id']);
          if (qid == null) continue;
          final key = '${exam.key}:$qid';
          byQuestion
              .putIfAbsent(
                key,
                () => AnalyticsItem(exam.key, exam.value, answer),
              )
              .add(answer);
        }
      }
    }
    final items = byQuestion.values.toList()
      ..sort((a, b) {
        final rate = b.missedRate.compareTo(a.missedRate);
        if (rate != 0) return rate;
        final count = b.incorrect.compareTo(a.incorrect);
        if (count != 0) return count;
        final exam = a.examId.compareTo(b.examId);
        return exam != 0 ? exam : a.questionId.compareTo(b.questionId);
      });
    return TeacherAnalyticsSummary._(percentages, items);
  }
}
