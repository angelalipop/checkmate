import 'package:checkmate/services/teacher_analytics.dart';
import 'package:test/test.dart';

AnalyticsJson answer(
  int id,
  bool? correct, {
  String status = 'verified',
  String response = 'B',
}) => {
  'question_id': id,
  'question_number': 1,
  'section_name': id == 1 ? 'Part I' : 'Part II',
  'is_correct': correct,
  'verification_status': status,
  'recognized_answer': response,
  'correct_answer': 'A',
};

AnalyticsJson attempt(
  int student,
  int section,
  List<AnalyticsJson> answers, {
  String status = 'completed',
  String score = '1',
  String max = '2',
}) => {
  'student_id': student,
  'student': {'class_id': section},
  'status': status,
  'score': score,
  'max_score': max,
  'answers': answers,
};

void main() {
  test(
    'class selection, completion, deduplication and repeated item numbers',
    () {
      final summary = TeacherAnalyticsSummary.fromAttempts(
        examTitles: {10: 'Quiz'},
        classIds: {20},
        attemptsByExam: {
          10: [
            attempt(1, 20, [answer(1, false), answer(2, true)]),
            attempt(1, 20, [answer(1, true), answer(2, true)]),
            attempt(2, 20, [
              answer(1, false, response: 'Unanswered'),
              answer(2, true),
            ]),
            attempt(3, 21, [answer(1, true)]),
            attempt(4, 20, [answer(1, true)], status: 'processing'),
            attempt(5, 20, [answer(1, null, status: 'needs_review')]),
            attempt(6, 20, [answer(1, true)], max: '0'),
          ],
        },
      );
      expect(summary.checked, 2);
      expect(summary.average, 50);
      expect(summary.buckets['0–59'], 2);
      expect(summary.items.length, 2);
      expect(summary.difficult, 1);
      expect(summary.easy, 1);
      expect(summary.missed.single.questionId, 1);
      expect(summary.missed.single.missedRate, 100);
      expect(summary.missed.single.unanswered, 1);
      expect(summary.missed.single.commonWrongAnswers.single.key, 'B');
      expect(summary.missed.single.commonWrongAnswers.single.value, 1);
    },
  );

  test('exam selection and empty results', () {
    final summary = TeacherAnalyticsSummary.fromAttempts(
      examTitles: {11: 'Final'},
      classIds: {20},
      attemptsByExam: {
        10: [
          attempt(1, 20, [answer(1, true)]),
        ],
      },
    );
    expect(summary.checked, 0);
    expect(summary.average, isNull);
    expect(summary.items, isEmpty);
  });

  test('score-only completed attempts do not imply item mastery', () {
    final summary = TeacherAnalyticsSummary.fromAttempts(
      examTitles: {10: 'Quiz'},
      classIds: {20},
      attemptsByExam: {
        10: [attempt(1, 20, [])],
      },
    );
    expect(summary.checked, 1);
    expect(summary.items, isEmpty);
    expect(summary.easy, 0);
  });
}
