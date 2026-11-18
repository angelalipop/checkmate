import 'package:flutter/material.dart';
import 'package:checkmate/theme/cm_theme.dart';

import '../services/teacher_analytics.dart';

class TeacherAnalyticsPanel extends StatefulWidget {
  const TeacherAnalyticsPanel({
    super.key,
    required this.classes,
    required this.exams,
    required this.attemptsByExam,
    required this.onRefresh,
  });

  final List<AnalyticsJson> classes, exams;
  final Map<int, List<AnalyticsJson>> attemptsByExam;
  final Future<void> Function() onRefresh;

  @override
  State<TeacherAnalyticsPanel> createState() => _TeacherAnalyticsPanelState();
}

class _TeacherAnalyticsPanelState extends State<TeacherAnalyticsPanel> {
  int _subject = 0, _section = 0, _exam = 0;
  bool _showAll = false;

  String _subjectLabel(Map subject) {
    final code = '${subject['code'] ?? ''}'.trim();
    final name = '${subject['name'] ?? 'Subject'}'.trim();
    return code.isEmpty ? name : '$code · $name';
  }

  String _classLabel(AnalyticsJson c) => [
    '${c['section'] ?? 'Section'}',
    if ('${c['school_year'] ?? ''}'.isNotEmpty) '${c['school_year']}',
    if ('${c['semester'] ?? ''}'.isNotEmpty) '${c['semester']}',
  ].join(' · ');

  Set<int> _classIds(AnalyticsJson exam) {
    final ids = <int>{};
    final primary = analyticsId(exam['class_id']);
    if (primary != null) ids.add(primary);
    final assigned = exam['class_ids'];
    if (assigned is List) {
      ids.addAll(assigned.map(analyticsId).whereType<int>());
    }
    return ids;
  }

  Widget _filter(
    String label,
    int value,
    Map<int, String> options,
    ValueChanged<int> onChanged,
  ) => DropdownButtonFormField<int>(
    key: ValueKey('$label:$value:${options.keys.join(',')}'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      fillColor: CmTheme.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CmTheme.lineBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CmTheme.lineBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: CmTheme.navy),
      ),
    ),
    dropdownColor: CmTheme.surfaceWhite,
    style: const TextStyle(
      color: CmTheme.navy,
      fontFamily: CmTheme.fontFamily,
      fontSize: 13,
    ),
    items: [
      for (final entry in options.entries)
        DropdownMenuItem(
          value: entry.key,
          child: Text(entry.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );

  @override
  Widget build(BuildContext context) {
    final subjects = <int, String>{0: 'All subjects'};
    for (final c in widget.classes) {
      final subject = c['subject'];
      if (subject is Map) {
        final id = analyticsId(subject['id']);
        if (id != null) subjects[id] = _subjectLabel(subject);
      }
    }
    final subjectId = subjects.containsKey(_subject) ? _subject : 0;
    final sections = <int, String>{0: 'All sections'};
    for (final c in widget.classes) {
      final id = analyticsId(c['id']);
      final subject = c['subject'];
      if (id == null ||
          (subjectId != 0 &&
              (subject is! Map || analyticsId(subject['id']) != subjectId)))
        continue;
      sections[id] = subjectId == 0 && subject is Map
          ? '${subject['code'] ?? subject['name'] ?? 'Subject'} · ${_classLabel(c)}'
          : _classLabel(c);
    }
    final sectionId = subjectId == _subject && sections.containsKey(_section)
        ? _section
        : 0;
    final selectedClasses = sections.keys
        .where((id) => id != 0 && (sectionId == 0 || sectionId == id))
        .toSet();
    final exams = <int, String>{0: 'All examinations'};
    for (final e in widget.exams) {
      final id = analyticsId(e['id']);
      if (id != null &&
          e['creation_mode'] != 'manual' &&
          _classIds(e).any(selectedClasses.contains)) {
        exams[id] = '${e['title'] ?? 'Untitled examination'}';
      }
    }
    final examId =
        sectionId == _section &&
            subjectId == _subject &&
            exams.containsKey(_exam)
        ? _exam
        : 0;
    final summary = TeacherAnalyticsSummary.fromAttempts(
      examTitles: Map.fromEntries(
        exams.entries.where(
          (e) => e.key != 0 && (examId == 0 || e.key == examId),
        ),
      ),
      classIds: selectedClasses,
      attemptsByExam: widget.attemptsByExam,
    );
    final controls = [
      _filter(
        'Subject',
        subjectId,
        subjects,
        (v) => setState(() {
          _subject = v;
          _section = 0;
          _exam = 0;
          _showAll = false;
        }),
      ),
      _filter(
        'Section',
        sectionId,
        sections,
        (v) => setState(() {
          _subject = subjectId;
          _section = v;
          _exam = 0;
          _showAll = false;
        }),
      ),
      _filter(
        'Examination',
        examId,
        exams,
        (v) => setState(() {
          _subject = subjectId;
          _section = sectionId;
          _exam = v;
          _showAll = false;
        }),
      ),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CmTheme.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CmTheme.lineBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Smart Analytics Dashboard',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: CmTheme.navy,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Analyze stored examination results by subject, section and examination.',
                      style: TextStyle(fontSize: 12, color: CmTheme.slateText),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Reset filters',
                onPressed: () => setState(() {
                  _subject = 0;
                  _section = 0;
                  _exam = 0;
                  _showAll = false;
                }),
                icon: const Icon(
                  Icons.filter_alt_off_outlined,
                  color: CmTheme.slateText,
                ),
              ),
              IconButton(
                tooltip: 'Refresh analytics',
                onPressed: () async {
                  await widget.onRefresh();
                },
                icon: const Icon(Icons.refresh, color: CmTheme.navy),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 650) {
                return Row(
                  children: [
                    for (var i = 0; i < controls.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: controls[i]),
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < controls.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    controls[i],
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          if (summary.checked == 0)
            const _AnalyticsNotice(
              'No completed scanned examination results for this selection. Scan and verify answer sheets to generate analytics. Manual score-only assessments are excluded.',
            )
          else ...[
            _heading('Class performance'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _metric('Average score', _pct(summary.average)),
                _metric('Highest score', _pct(summary.highest)),
                _metric('Lowest score', _pct(summary.lowest)),
                _metric('Exam attempts', '${summary.checked}'),
                _metric(
                  'Highest error rate',
                  summary.missed.isEmpty
                      ? (summary.items.isEmpty ? '—' : '0.0%')
                      : _pct(summary.missed.first.missedRate),
                  color: summary.missed.isEmpty
                      ? CmTheme.slateText
                      : CmTheme.redDanger,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _heading('Score distribution'),
            const SizedBox(height: 12),
            _distribution(summary),
            const SizedBox(height: 20),
            if (summary.items.isEmpty)
              const _AnalyticsNotice(
                'Scores are available, but there are no scored question-level responses for this selection.',
              )
            else ...[
              _heading('Item difficulty'),
              const SizedBox(height: 6),
              const Text(
                'Based on the percentage of scored responses that are correct.',
                style: TextStyle(fontSize: 12, color: CmTheme.slateText),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _metric(
                    'Easy · 80%+',
                    '${summary.easy}',
                    color: CmTheme.emeraldSuccess,
                  ),
                  _metric(
                    'Moderate · 40–79%',
                    '${summary.moderate}',
                    color: CmTheme.slateText,
                  ),
                  _metric(
                    'Difficult · below 40%',
                    '${summary.difficult}',
                    color: CmTheme.amberWarning,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _heading('Frequently missed questions'),
              const SizedBox(height: 4),
              const Text(
                'Ranked by incorrect-response rate. Expand an item for answer details.',
                style: TextStyle(color: CmTheme.slateText, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (summary.missed.isEmpty)
                const _AnalyticsNotice(
                  'No incorrect responses among the scored items.',
                )
              else ...[
                for (final item
                    in (_showAll ? summary.missed : summary.missed.take(5)))
                  _question(item),
                if (summary.missed.length > 5)
                  TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(
                      _showAll
                          ? 'Show fewer'
                          : 'Show all ${summary.missed.length} missed questions',
                      style: const TextStyle(color: CmTheme.navy),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              _heading('Teaching insights'),
              const SizedBox(height: 8),
              _AnalyticsNotice(
                summary.difficult > 0
                    ? '${summary.difficult} item(s) have less than 40% accuracy. Prioritize the questions at the top of the missed-items list for review.'
                    : summary.moderate > 0
                    ? '${summary.moderate} item(s) have 40–79% accuracy. Consider targeted practice on these items.'
                    : 'All scored items achieved at least 80% accuracy.',
                warning: summary.difficult > 0 || summary.moderate > 0,
              ),
            ],
            const SizedBox(height: 10),
            const Text(
              'Only completed, scored attempts and finalized question responses are included. An exam attempt is one student–exam record; combined results are not a final grade. Manual score-only assessments are excluded.',
              style: TextStyle(fontSize: 11, color: CmTheme.slateText),
            ),
          ],
        ],
      ),
    );
  }

  String _pct(double? n) => n == null ? '—' : '${n.toStringAsFixed(1)}%';
  Widget _heading(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: CmTheme.navy,
    ),
  );

  Widget _metric(String label, String value, {Color color = CmTheme.navy}) =>
      Container(
        constraints: const BoxConstraints(minWidth: 130),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CmTheme.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: CmTheme.lineBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: CmTheme.slateText, fontSize: 12),
            ),
          ],
        ),
      );

  Widget _distribution(TeacherAnalyticsSummary summary) {
    final buckets = summary.buckets;
    final max = buckets.values.fold<int>(1, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 130,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final entry in buckets.entries)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '${entry.value}',
                      style: const TextStyle(color: CmTheme.navy, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: entry.value == 0 ? 3 : 80 * entry.value / max,
                      decoration: BoxDecoration(
                        color: entry.value == 0
                            ? CmTheme.lineBorder
                            : CmTheme.navy,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: CmTheme.slateText,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _question(AnalyticsItem item) {
    final difficultyColor = item.accuracy < 40
        ? CmTheme.amberWarning
        : item.accuracy < 80
        ? CmTheme.slateText
        : CmTheme.emeraldSuccess;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: CmTheme.lineBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ExpansionTile(
        key: ValueKey('${item.examId}:${item.questionId}'),
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: CmTheme.transparent),
        ),
        collapsedShape: const RoundedRectangleBorder(
          side: BorderSide(color: CmTheme.transparent),
        ),
        iconColor: CmTheme.navy,
        collapsedIconColor: CmTheme.slateText,
        title: Text(
          '${item.section} · Item ${item.number}',
          style: const TextStyle(
            color: CmTheme.navy,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.examTitle,
              style: const TextStyle(color: CmTheme.slateText, fontSize: 12),
            ),
            Text(
              '${_pct(item.missedRate)} missed · ${item.incorrect}/${item.total} responses',
              style: const TextStyle(color: CmTheme.redDanger, fontSize: 12),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.question.isEmpty
                ? 'Question text not available (answer-key-only item).'
                : item.question,
            style: const TextStyle(color: CmTheme.navy),
          ),
          const SizedBox(height: 8),
          Text(
            'Difficulty: ${item.difficulty} · ${_pct(item.accuracy)} accuracy',
            style: TextStyle(
              color: difficultyColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Correct key: ${item.correctAnswer.isEmpty ? 'Not available' : item.correctAnswer}',
            style: TextStyle(
              color: item.correctAnswer.isEmpty
                  ? CmTheme.slateText
                  : CmTheme.emeraldSuccess,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Correct: ${item.correct}  |  Incorrect: ${item.incorrect}  |  Unanswered: ${item.unanswered}',
            style: const TextStyle(color: CmTheme.slateText, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            'Common incorrect answers',
            style: TextStyle(color: CmTheme.navy, fontWeight: FontWeight.w600),
          ),
          if (item.commonWrongAnswers.isEmpty)
            const Text(
              'No nonblank incorrect responses recorded.',
              style: TextStyle(color: CmTheme.slateText),
            ),
          for (final entry in item.commonWrongAnswers.take(3))
            Text(
              '${entry.key} — ${entry.value} response(s)',
              style: const TextStyle(color: CmTheme.redDanger),
            ),
        ],
      ),
    );
  }
}

class _AnalyticsNotice extends StatelessWidget {
  const _AnalyticsNotice(this.message, {this.warning = false});
  final String message;
  final bool warning;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: warning
          ? CmTheme.amberWarning.withValues(alpha: 0.10)
          : CmTheme.background,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(
          warning ? Icons.warning_amber_rounded : Icons.info_outline,
          color: warning ? CmTheme.amberWarning : CmTheme.slateText,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: CmTheme.navy, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
