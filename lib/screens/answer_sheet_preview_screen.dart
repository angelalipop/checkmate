import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';

class AnswerSheetPreviewScreen extends StatefulWidget {
  final int examId;

  const AnswerSheetPreviewScreen({
    super.key,
    required this.examId,
  });

  @override
  State<AnswerSheetPreviewScreen> createState() =>
      _AnswerSheetPreviewScreenState();
}

class _AnswerSheetPreviewScreenState extends State<AnswerSheetPreviewScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  Map<String, dynamic>? _exam;
  List<Map<String, dynamic>> _sections = [];
  final Map<int, List<Map<String, dynamic>>> _questions = {};
  List<Map<String, dynamic>> _students = [];

  @override
  void initState() {
    super.initState();
    _loadAnswerSheet();
  }

  Future<void> _loadAnswerSheet() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Your session has expired. Please log in again.',
        );
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(
        token,
        widget.examId,
      );

      final questionsBySection = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(
          section['id']?.toString() ?? '',
        );

        if (sectionId == null) {
          continue;
        }

        final questions = await ApiService.getQuestions(
          token,
          sectionId,
        );

        questionsBySection[sectionId] = questions;
      }

      final students = await ApiService.getExamStudents(token, exam);

      if (!mounted) return;

      setState(() {
        _exam = exam;
        _sections = sections;
        _questions
          ..clear()
          ..addAll(questionsBySection);
        _students = students;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = e.toString().replaceFirst(
          'Exception: ',
          '',
        );
        _isLoading = false;
      });
    }
  }

  Future<Uint8List> _generatePdf() async {
    final exam = _exam;
    if (exam == null) throw Exception('Exam not loaded.');
    return AnswerSheetPdfService.generate(
      exam: exam,
      sections: _sections,
      questions: _questions,
      students: _students,
    );
  }

  String _fileName() {
    final title = (_exam?['title']?.toString() ?? 'exam')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'answer_sheet_${title.isEmpty ? 'exam' : title}.pdf';
  }

  Future<void> _printAnswerSheets() async {
    try {
      final bytes = await _generatePdf();
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _downloadAnswerSheets() async {
    try {
      final bytes = await _generatePdf();
      await Printing.sharePdf(bytes: bytes, filename: _fileName());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
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
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadAnswerSheet,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return PdfPreview(
      build: (format) => _generatePdf(),
      useActions: false,
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      maxPageWidth: 780,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Answer Sheet Preview',
        ),
        actions: [
          if (!_isLoading && _errorMessage == null) ...[
            IconButton(
              tooltip: 'Print Answer Sheets',
              onPressed: _printAnswerSheets,
              icon: const Icon(Icons.print_outlined),
            ),
            IconButton(
              tooltip: 'Download Answer Sheet PDF',
              onPressed: _downloadAnswerSheets,
              icon: const Icon(Icons.file_download_outlined),
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }
}
