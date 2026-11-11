/// Explicit stored types only; historical titles are never guessed.
class GradingCalculator {
  static const periods = ['prelims', 'midterm', 'pre_finals', 'finals'];
  static const categories = ['pt', 'quiz', 'exam'];
  static const defaults = <String, num>{
    'pt': 30,
    'quiz': 20,
    'exam': 50,
    'prelims': 20,
    'midterm': 20,
    'pre_finals': 20,
    'finals': 40,
  };
  static String? category(Object? type) {
    return switch (type) {
      'quiz' || 'short_quiz' || 'long_quiz' => 'quiz',
      'performance_task' || 'laboratory' => 'pt',
      'prelim' ||
      'midterm' ||
      'prefinal' ||
      'pre_finals' ||
      'final' ||
      'finals' => 'exam',
      _ => null,
    };
  }

  static String? majorPeriod(Object? type) => switch (type) {
    'prelim' => 'prelims',
    'midterm' => 'midterm',
    'prefinal' || 'pre_finals' => 'pre_finals',
    'final' || 'finals' => 'finals',
    _ => null,
  };
  static String? validatePeriod(String? raw, Object? type) {
    final forced = majorPeriod(type);
    if (raw != null && !periods.contains(raw))
      throw ArgumentError('Choose a valid grading period.');
    if (forced != null && raw != null && forced != raw)
      throw ArgumentError('Major examination has a fixed grading period.');
    return forced ?? raw;
  }

  static Map<String, num> validatePreferences(Map<String, dynamic> input) {
    final out = <String, num>{};
    for (final k in defaults.keys) {
      final n = num.tryParse('${input[k]}');
      if (n == null ||
          !n.isFinite ||
          n < 0 ||
          n > 100 ||
          (n * 100 - (n * 100).round()).abs() > 0.000001) {
        throw ArgumentError(
          'Weights must be between 0 and 100, with at most two decimal places.',
        );
      }
      out[k] = n;
    }
    for (final keys in [categories, periods]) {
      if (keys.fold<int>(0, (s, k) => s + (out[k]! * 100).round()) != 10000)
        throw ArgumentError(
          'Each weight distribution must total exactly 100%.',
        );
    }
    return out;
  }

  static Map<String, dynamic> student(
    List<Map<String, dynamic>> assessments,
    List<Map<String, dynamic>> cells,
    Map<String, num> weights,
  ) {
    final byId = {for (final c in cells) c['exam_id']: c};
    final result = <String, dynamic>{};
    // Unknown historical assessments block a final grade until confirmed.
    final unclassified = assessments.any(
      (a) =>
          a['grading_period'] == null || category(a['assessment_type']) == null,
    );
    double applicable = 0;
    double applicableWeight = 0;
    bool finalComplete = !unclassified;
    for (final p in periods) {
      final cats = <String, dynamic>{};
      double total = 0;
      bool complete = true;
      for (final k in categories) {
        final items = assessments
            .where(
              (a) =>
                  a['grading_period'] == p &&
                  category(a['assessment_type']) == k &&
                  a['grade_eligible'] == true,
            )
            .toList();
        final values = <double>[];
        bool valid = items.isNotEmpty;
        for (final a in items) {
          final c = byId[a['id']];
          final score = num.tryParse('${c?['score']}');
          final max = num.tryParse('${c?['max_score']}');
          if (c?['status'] != 'completed' ||
              score == null ||
              max == null ||
              !score.isFinite ||
              !max.isFinite ||
              max <= 0 ||
              score < 0 ||
              score > max) {
            valid = false;
            continue;
          }
          values.add(score / max * 100);
        }
        final double? percentage = valid
            ? values.reduce((a, b) => a + b) / items.length
            : null;
        final w = weights[k]!.toDouble();
        final double? contribution = w == 0
            ? 0.0
            : percentage == null
            ? null
            : percentage * w / 100;
        cats[k] = {
          'percentage': percentage,
          'contribution': contribution,
          'weight': w,
          'assessment_count': items.length,
        };
        if (contribution == null)
          complete = false;
        else
          total += contribution;
      }
      final double? grade = complete ? total : null;
      final pw = weights[p]!.toDouble();
      final double? contribution = pw == 0
          ? 0.0
          : grade == null
          ? null
          : grade * pw / 100;
      if (pw > 0) {
        if (grade == null)
          finalComplete = false;
        else {
          applicable += grade * pw / 100;
          applicableWeight += pw;
        }
      }
      result[p] = {
        'categories': cats,
        'grade': grade,
        'weight': pw,
        'contribution': contribution,
        'status': grade == null ? 'INC' : 'Recorded',
      };
    }
    result['final_grade'] = finalComplete ? applicable : null;
    // Interim is explicitly labeled: contribution of completed periods, unnormalized.
    result['interim_contribution'] = applicableWeight > 0 ? applicable : null;
    result['completed_period_weight'] = applicableWeight;
    result['status'] = finalComplete ? 'Recorded' : 'INC';
    result['requires_classification'] = unclassified;
    return result;
  }
}
