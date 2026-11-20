import 'package:checkmate/theme/cm_theme.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/assessment_validator.dart';
import '../services/auth_storage.dart';
import '../services/question_paper_pdf_service.dart';
import 'answer_sheet_preview_screen.dart';
import 'exam_preview_screen.dart';
import 'exams_tab.dart'
    show
        buildExamBuilderPane,
        importParsedSectionsIntoExam,
        resequenceExamSectionHeadings,
        showExamSectionDialog,
        showUploadQuestionnaireModal;
import 'questions_screen.dart';
import 'teacher_dashboard.dart' show openTeacherScansForExam;

class ExamBuilderScreen extends StatefulWidget {
  final int examId;

  const ExamBuilderScreen({super.key, required this.examId});

  @override
  State<ExamBuilderScreen> createState() => _ExamBuilderScreenState();
}

class _ExamBuilderScreenState extends State<ExamBuilderScreen> {
  bool _isLoading = true;
  bool _isUpdatingStatus = false;
  String? _errorMessage;

  Map<String, dynamic>? _exam;
  List<Map<String, dynamic>> _sections = [];
  final Map<int, List<Map<String, dynamic>>> _questions = {};
  List<Map<String, dynamic>> _students = [];

  @override
  void initState() {
    super.initState();
    _loadExam();
  }

  Future<void> _loadExam() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;
      if (exam['creation_mode'] == 'answer_key') {
        if (!mounted) return;
        setState(() {
          _exam = exam;
          _isLoading = false;
        });
        return;
      }

      final sections = await ApiService.getExamSections(token, widget.examId);
      sections.sort((a, b) {
        final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
        final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
        if (oa != ob) return oa.compareTo(ob);
        final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
        final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
        return ida.compareTo(idb);
      });

      final questionsMap = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');
        if (sectionId == null) continue;
        final qList = await ApiService.getQuestions(token, sectionId);
        qList.sort((a, b) {
          final na = int.tryParse(a['question_number']?.toString() ?? '') ?? 0;
          final nb = int.tryParse(b['question_number']?.toString() ?? '') ?? 0;
          if (na != nb) return na.compareTo(nb);
          final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
          final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
          return ida.compareTo(idb);
        });
        questionsMap[sectionId] = qList;
      }

      final students = await ApiService.getExamStudents(token, exam);

      if (!mounted) return;

      setState(() {
        _exam = exam;
        _sections = sections;
        _questions
          ..clear()
          ..addAll(questionsMap);
        _students = students;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  AssessmentValidationResult get _validation {
    return AssessmentValidator.validate(
      assessmentType: _exam?['assessment_type']?.toString(),
      title: _exam?['title']?.toString(),
      description: _exam?['description']?.toString(),
      sections: _sections,
      questionsBySectionId: _questions,
    );
  }

  bool get _isPublished =>
      (_exam?['status']?.toString() ?? 'draft').trim().toLowerCase() ==
      'published';

  Future<void> _updateAssessmentStatus(String targetStatus) async {
    if (_isPublished) return;
    final exam = _exam;
    if (exam == null || _isUpdatingStatus) return;

    final validation = _validation;
    if (targetStatus == 'published' && !validation.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          validation.errors.join('\n'),
          color: CmTheme.redDanger,
        ),
      );
      return;
    }

    setState(() => _isUpdatingStatus = true);
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      await ApiService.updateExam(
        token: token,
        examId: widget.examId,
        title: exam['title']?.toString() ?? 'Exam',
        description: exam['description']?.toString(),
        instructions: exam['instructions']?.toString(),
        assessmentType: exam['assessment_type']?.toString(),
        status: targetStatus,
      );

      if (!mounted) return;
      await _loadExam();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          targetStatus == 'published'
              ? 'Assessment published successfully.'
              : 'Assessment saved as draft.',
          color: CmTheme.emeraldSuccess,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          e.toString().replaceFirst('Exception: ', ''),
          color: CmTheme.redDanger,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingStatus = false);
      }
    }
  }

  Future<void> _deleteSection(int sectionId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete section?'),
        content: Text(
          'Delete "$name" and all its questions? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmTheme.redDanger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) throw Exception('Session expired.');
      await ApiService.deleteExamSection(token: token, sectionId: sectionId);
      await resequenceExamSectionHeadings(token: token, examId: widget.examId);
      if (!mounted) return;
      await _loadExam();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          'Section deleted.',
          color: CmTheme.emeraldSuccess,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          e.toString().replaceFirst('Exception: ', ''),
          color: CmTheme.redDanger,
        ),
      );
    }
  }

  Future<void> _generateQuestionPaperPdf({
    bool download = false,
    bool asDocx = false,
  }) async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(token, widget.examId);

      final questions = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] = await ApiService.getQuestions(token, sectionId);
      }

      if (download && asDocx) {
        final docxBytes = await QuestionPaperPdfService.generateDocx(
          exam: exam,
          sections: sections,
          questions: questions,
        );
        await Printing.sharePdf(
          bytes: docxBytes,
          filename: _docFileName('questionnaire', exam, 'docx'),
        );
        return;
      }

      final pdfBytes = await QuestionPaperPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
      );

      if (download) {
        await Printing.sharePdf(
          bytes: pdfBytes,
          filename: _pdfFileName('questionnaire', exam),
        );
      } else {
        await Printing.layoutPdf(
          onLayout: (format) async {
            return pdfBytes;
          },
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          e.toString().replaceFirst('Exception: ', ''),
          color: CmTheme.redDanger,
        ),
      );
    }
  }

  Future<void> _generateAnswerSheetPdf({bool download = false}) async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(token, widget.examId);

      final questions = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] = await ApiService.getQuestions(token, sectionId);
      }

      final students = await ApiService.getExamStudents(token, exam);

      final pdfBytes = await AnswerSheetPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
        students: students,
      );

      if (download) {
        await Printing.sharePdf(
          bytes: pdfBytes,
          filename: _pdfFileName('answer_sheet', exam),
        );
      } else {
        await Printing.layoutPdf(
          onLayout: (format) async {
            return pdfBytes;
          },
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          e.toString().replaceFirst('Exception: ', ''),
          color: CmTheme.redDanger,
        ),
      );
    }
  }

  Future<void> _importPdfIntoCurrentExam() async {
    final parsedPaper = await showUploadQuestionnaireModal(context);
    if (parsedPaper == null || !mounted) return;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Please log in again.');
      }
      final nextOrder =
          _sections.fold<int>(0, (m, s) {
            final o = int.tryParse(s['section_order']?.toString() ?? '') ?? 0;
            return o > m ? o : m;
          }) +
          1;
      final count = await importParsedSectionsIntoExam(
        token: token,
        examId: widget.examId,
        paper: parsedPaper,
        startingSectionOrder: nextOrder,
        existingSections: _sections,
        existingQuestionsBySection: _questions,
      );
      await _loadExam();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported $count questions from "${parsedPaper.fileName}".',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        CmTheme.feedbackSnackBar(
          e.toString().replaceFirst('Exception: ', ''),
          color: CmTheme.redDanger,
        ),
      );
    }
  }

  Future<void> _showSectionDialog({
    Map<String, dynamic>? section,
    int? sectionIndex,
  }) async {
    final saved = await showExamSectionDialog(
      context,
      examId: widget.examId,
      sections: _sections,
      section: section,
      sectionIndex: sectionIndex,
    );
    if (saved == null || !mounted) return;
    if (saved.itemCount > 0) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (routeContext) => Scaffold(
            body: SafeArea(
              child: buildExamBuilderPane(
                examId: widget.examId,
                initialSectionId: saved.sectionId,
                initialItemCount: saved.itemCount,
                onBack: () => Navigator.maybePop(routeContext),
              ),
            ),
          ),
        ),
      );
    }
    if (mounted) await _loadExam();
  }

  String _pdfFileName(String prefix, Map<String, dynamic> exam) =>
      _docFileName(prefix, exam, 'pdf');

  String _docFileName(
    String prefix,
    Map<String, dynamic> exam,
    String extension,
  ) {
    final title = (exam['title']?.toString() ?? 'exam')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '${prefix}_${title.isEmpty ? 'exam' : title}.$extension';
  }

  Widget _buildValidationCard() {
    final validation = _validation;
    final published = _isPublished;
    final isValid = validation.isValid;
    final hasWarnings = !published && validation.itemCountWarnings.isNotEmpty;
    final ready = published || (isValid && !hasWarnings);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ready ? Icons.check_circle_outline : Icons.info_outline,
                  color: ready
                      ? CmTheme.emeraldSuccess
                      : (isValid ? CmTheme.amberWarning : CmTheme.redDanger),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Publishing',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: CmTheme.navy,
                    ),
                  ),
                ),
              ],
            ),
            if (!published && !isValid) ...[
              const SizedBox(height: 8),
              for (final err in validation.errors)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• $err',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: CmTheme.redDanger,
                    ),
                  ),
                ),
            ],
            if (hasWarnings) ...[
              const SizedBox(height: 8),
              for (final warning in validation.itemCountWarnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    warning,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: CmTheme.slateText,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            if (published)
              FilledButton.icon(
                onPressed: () =>
                    openTeacherScansForExam(context, widget.examId),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('Scan Now'),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isUpdatingStatus
                        ? null
                        : () => _updateAssessmentStatus('draft'),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save Draft'),
                  ),
                  FilledButton.icon(
                    onPressed: (_isUpdatingStatus || !isValid)
                        ? null
                        : () => _updateAssessmentStatus('published'),
                    icon: const Icon(Icons.publish_outlined, size: 18),
                    label: const Text('Publish Assessment'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoading &&
        _errorMessage == null &&
        _exam?['creation_mode'] == 'answer_key') {
      return Scaffold(
        body: SafeArea(
          child: buildExamBuilderPane(
            examId: widget.examId,
            onBack: () => Navigator.maybePop(context),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Exam Builder')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: CmTheme.redDanger,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: CmTheme.redDanger),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadExam, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadExam,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _exam?['title']?.toString() ?? 'Exam',
            style: Theme.of(context).textTheme.headlineSmall,
          ),

          const SizedBox(height: 8),

          Text(
            _exam?['description']?.toString() ?? '',
            style: Theme.of(context).textTheme.bodyMedium,
          ),

          const SizedBox(height: 16),

          _buildValidationCard(),

          // PREVIEW QUESTIONNAIRE
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExamPreviewScreen(examId: widget.examId),
                  ),
                );
              },
              child: const Text('Preview Questionnaire'),
            ),
          ),

          const SizedBox(height: 10),

          // PRINT QUESTIONNAIRE PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateQuestionPaperPdf,
              child: const Text('Print Questionnaire'),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  _generateQuestionPaperPdf(download: true, asDocx: true),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Download Questionnaire (Word .docx)'),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _generateQuestionPaperPdf(download: true),
              icon: const Icon(Icons.download),
              label: const Text('Download Questionnaire PDF'),
            ),
          ),

          const SizedBox(height: 10),

          // PREVIEW ANSWER SHEET
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AnswerSheetPreviewScreen(examId: widget.examId),
                  ),
                );
              },
              child: const Text('Preview Answer Sheet'),
            ),
          ),

          const SizedBox(height: 10),

          // GENERATE ANSWER SHEET PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateAnswerSheetPdf,
              child: Text(
                'Print Answer Sheets '
                '(${_students.isEmpty ? 'Template' : '${_students.length} students'})',
              ),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _generateAnswerSheetPdf(download: true),
              icon: const Icon(Icons.download),
              label: const Text('Download Answer Sheet PDF'),
            ),
          ),

          const SizedBox(height: 24),

          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              const Text(
                'Exam Sections',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              if (!_isPublished)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _importPdfIntoCurrentExam,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Upload Questionnaire'),
                    ),
                    FilledButton.icon(
                      onPressed: () => _showSectionDialog(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Section'),
                    ),
                  ],
                ),
            ],
          ),

          const SizedBox(height: 12),

          if (_sections.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text('No sections have been added yet.'),
              ),
            ),

          for (var idx = 0; idx < _sections.length; idx++)
            Builder(
              builder: (context) {
                final section = _sections[idx];
                final type = section['question_type']?.toString() ?? '';
                final sectionId = int.tryParse(section['id']?.toString() ?? '');
                final secQs = sectionId == null
                    ? const <Map<String, dynamic>>[]
                    : (_questions[sectionId] ?? const <Map<String, dynamic>>[]);
                final qCount = secQs.length;
                final rangeLabel = secQs.isEmpty
                    ? '0 questions'
                    : 'Items ${secQs.first['question_number'] ?? 1}\u2013${secQs.last['question_number'] ?? qCount} ($qCount items)';

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    onTap: sectionId == null
                        ? null
                        : () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => QuestionsScreen(
                                  sectionId: sectionId,
                                  sectionName:
                                      section['name']?.toString() ?? 'Section',
                                  questionType: type,
                                ),
                              ),
                            );
                            if (mounted) {
                              await _loadExam();
                            }
                          },
                    leading: CircleAvatar(
                      child: Text(
                        section['section_order']?.toString() ?? '${idx + 1}',
                      ),
                    ),
                    title: Text(section['name']?.toString() ?? 'Section'),
                    subtitle: Text(
                      '${AssessmentValidator.questionTypeLabel(type)} • '
                      '${section['default_points'] ?? '1'} pts/item • '
                      '$rangeLabel',
                    ),
                    trailing: _isPublished
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Edit section',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _showSectionDialog(
                                  section: section,
                                  sectionIndex: idx,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Delete section',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: sectionId == null
                                    ? null
                                    : () => _deleteSection(
                                        sectionId,
                                        section['name']?.toString() ??
                                            'Section',
                                      ),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
