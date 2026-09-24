
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class QuestionPaperPdfService {
  static Future<Uint8List> generate({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) async {
    final pdf = pw.Document();

    final examTitle =
        exam['title']?.toString() ?? 'Exam';

    final description =
        exam['description']?.toString() ?? '';

    final instructions =
        exam['instructions']?.toString() ?? '';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (context) {
          return pw.Column(
            children: [
              pw.Text(
                'CHECKMATE',
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                examTitle,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Divider(),
            ],
          );
        },
        footer: (context) {
          return pw.Row(
            mainAxisAlignment:
                pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Exam ID: ${exam['id']}',
                style: const pw.TextStyle(
                  fontSize: 9,
                ),
              ),
              pw.Text(
                'Page ${context.pageNumber} of '
                '${context.pagesCount}',
                style: const pw.TextStyle(
                  fontSize: 9,
                ),
              ),
            ],
          );
        },
        build: (context) {
          final content = <pw.Widget>[];

          // ----------------------------------------------------
          // EXAM INFORMATION
          // ----------------------------------------------------

          if (description.isNotEmpty) {
            content.add(
              pw.Text(
                description,
                style: const pw.TextStyle(
                  fontSize: 11,
                ),
              ),
            );

            content.add(
              pw.SizedBox(height: 10),
            );
          }

          // ----------------------------------------------------
          // STUDENT INFORMATION
          // ----------------------------------------------------

          content.add(
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(),
              ),
              child: pw.Column(
                crossAxisAlignment:
                    pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'STUDENT INFORMATION',
                    style: pw.TextStyle(
                      fontWeight:
                          pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 12),
                  pw.Text(
                    'Student Name: '
                    '________________________________________',
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(
                    'Student Number: '
                    '_____________________________________',
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(
                    'Section: '
                    '____________________________________________',
                  ),
                ],
              ),
            ),
          );

          content.add(
            pw.SizedBox(height: 15),
          );

          // ----------------------------------------------------
          // INSTRUCTIONS
          // ----------------------------------------------------

          if (instructions.isNotEmpty) {
            content.add(
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(),
                ),
                child: pw.Column(
                  crossAxisAlignment:
                      pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'INSTRUCTIONS',
                      style: pw.TextStyle(
                        fontWeight:
                            pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Text(
                      instructions,
                    ),
                  ],
                ),
              ),
            );

            content.add(
              pw.SizedBox(height: 20),
            );
          }

          // ----------------------------------------------------
          // SECTIONS
          // ----------------------------------------------------

          for (final section in sections) {
            final sectionId = int.tryParse(
              section['id']?.toString() ?? '',
            );

            if (sectionId == null) {
              continue;
            }

            final sectionName =
                section['name']?.toString() ??
                    'Section';

            final questionType =
                section['question_type']?.toString() ??
                    '';

            final sectionQuestions =
                questions[sectionId] ?? [];

            content.add(
              pw.Container(
                width: double.infinity,
                padding:
                    const pw.EdgeInsets.all(10),
                margin:
                    const pw.EdgeInsets.only(
                  bottom: 15,
                ),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(),
                ),
                child: pw.Column(
                  crossAxisAlignment:
                      pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      sectionName.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight:
                            pw.FontWeight.bold,
                      ),
                    ),

                    pw.SizedBox(height: 10),

                    ...sectionQuestions
                        .asMap()
                        .entries
                        .map(
                      (entry) {
                        final question =
                            entry.value;

                        final number =
                            question[
                                    'question_number']
                                ?.toString() ??
                            '${entry.key + 1}';

                        final text =
                            question[
                                    'question_text']
                                ?.toString() ??
                            '';

                        final points =
                            question['points']
                                    ?.toString() ??
                                '0';

                        final choices =
                            question['choices'];

                        final questionWidgets =
                            <pw.Widget>[];

                        // Question text
                        questionWidgets.add(
                          pw.Text(
                            '$number. $text '
                            '($points pts)',
                            style:
                                const pw.TextStyle(
                              fontSize: 11,
                            ),
                          ),
                        );

                        // Multiple choice
                        if (questionType ==
                            'multiple_choice') {
                          if (choices is List) {
                            questionWidgets.add(
                              pw.SizedBox(
                                height: 5,
                              ),
                            );

                            for (
                              int i = 0;
                              i < choices.length;
                              i++
                            ) {
                              final choice =
                                  choices[i];

                              questionWidgets.add(
                                pw.Padding(
                                  padding:
                                      const pw.EdgeInsets
                                          .only(
                                    left: 15,
                                    bottom: 3,
                                  ),
                                  child: pw.Text(
                                    '${String.fromCharCode(65 + i)}. '
                                    '${choice.toString()}',
                                    style:
                                        const pw.TextStyle(
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }

                        questionWidgets.add(
                          pw.SizedBox(height: 12),
                        );

                        return pw.Column(
                          crossAxisAlignment:
                              pw.CrossAxisAlignment
                                  .start,
                          children:
                              questionWidgets,
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          }

          return content;
        },
      ),
    );

    return pdf.save();
  }
}
