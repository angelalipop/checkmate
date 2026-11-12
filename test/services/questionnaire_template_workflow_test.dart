import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:checkmate/services/assessment_validator.dart';
import 'package:checkmate/services/question_paper_import_service.dart';
import 'package:checkmate/services/question_paper_pdf_service.dart';
import 'package:checkmate/services/answer_sheet_pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _fillTemplateDocx(
  Uint8List templateDocxBytes, {
  Map<int, String>? customPrompts,
}) {
  final archive = ZipDecoder().decodeBytes(templateDocxBytes);
  final outArchive = Archive();

  for (final file in archive.files) {
    if (file.name == 'word/document.xml') {
      var xml = utf8.decode(file.content as List<int>);
      var qCounter = 0;
      xml = xml.replaceAllMapped(
        RegExp(r'\[Write (?:question|statement) here\]'),
        (m) {
          qCounter++;
          return customPrompts?[qCounter] ??
              'Sample question prompt for item $qCounter?';
        },
      );
      for (final letter in const ['A', 'B', 'C', 'D']) {
        var cCounter = 0;
        xml = xml.replaceAllMapped(
          RegExp('\\[Write choice $letter here\\]'),
          (_) {
            cCounter++;
            return 'Option $letter for item $cCounter';
          },
        );
      }
      final encoded = utf8.encode(xml);
      outArchive.addFile(ArchiveFile(file.name, encoded.length, encoded));
    } else {
      outArchive.addFile(file);
    }
  }

  return Uint8List.fromList(ZipEncoder().encode(outArchive));
}

void main() {
  group('Upload Questionnaire Template & Import Workflow Verification', () {
    test(
      '1. Default 35-item Multiple Choice template exports, fills, converts to PDF, and imports cleanly',
      () async {
        final defaultSections =
            QuestionPaperImportService.templatePresets.first.sections;
        expect(defaultSections.length, 1);
        expect(defaultSections.first.questionType, 'multiple_choice');
        expect(defaultSections.first.itemCount, 35);
        expect(defaultSections.first.pointsPerItem, 1.0);

        final templateDocx = await QuestionPaperPdfService.generateTemplateDocx(
          sections: defaultSections,
        );
        final filledDocx = _fillTemplateDocx(templateDocx);

        // Parse filled Word template and render to PDF, then parse the PDF in a fresh call
        final parsedFromWord = QuestionPaperImportService.parseBytes(
          bytes: filledDocx,
          fileName: 'filled_35_mc.docx',
        );
        expect(parsedFromWord.totalQuestions, 35);
        expect(parsedFromWord.sections.length, 1);
        expect(parsedFromWord.sections.first.name, 'Part I. Multiple Choice');

        final pdfBytes = await QuestionPaperPdfService.generate(
          exam: <String, dynamic>{
            'id': '1',
            'title': 'Sample Quiz',
            'subject_name': 'Information Assurance and Security',
            'assessment_type': 'quiz',
          },
          sections: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 1,
              'name': parsedFromWord.sections.first.name,
              'question_type': 'multiple_choice',
              'section_order': 1,
              'default_points': 1.0,
            },
          ],
          questions: <int, List<Map<String, dynamic>>>{
            1: parsedFromWord.sections.first.questions
                .map(
                  (q) => <String, dynamic>{
                    'id': q.questionNumber,
                    'question_number': q.questionNumber,
                    'question_text': q.questionText,
                    'points': q.points,
                    'choices': q.choices,
                  },
                )
                .toList(),
          },
        );

        final parsedFromPdf = QuestionPaperImportService.parseBytes(
          bytes: pdfBytes,
          fileName: 'filled_35_mc.pdf',
          expectedTemplate: defaultSections,
        );
        expect(parsedFromPdf.totalQuestions, 35);
        expect(parsedFromPdf.totalPoints, 35.0);
        expect(parsedFromPdf.sections.length, 1);
        expect(parsedFromPdf.sections.first.name, 'Part I. Multiple Choice');
        expect(parsedFromPdf.hasBlockingIssues, isFalse);
        for (var i = 0; i < 35; i++) {
          final q = parsedFromPdf.sections.first.questions[i];
          expect(q.questionNumber, i + 1);
          expect(q.choices.length, 4);
          expect(q.missingChoiceLetters, isEmpty);
        }
      },
    );

    test(
      '2. 50-item Multiple Choice template preserves all 50 items and A-D choices across PDF export and import',
      () async {
        const mc50 = <QuestionnaireTemplateSectionConfig>[
          QuestionnaireTemplateSectionConfig(
            questionType: 'multiple_choice',
            itemCount: 50,
            pointsPerItem: 1.0,
          ),
        ];

        final templateDocx = await QuestionPaperPdfService.generateTemplateDocx(
          sections: mc50,
        );
        final filledDocx = _fillTemplateDocx(templateDocx);
        final parsedDocx = QuestionPaperImportService.parseBytes(
          bytes: filledDocx,
          fileName: 'filled_50_mc.docx',
          expectedTemplate: mc50,
        );
        expect(parsedDocx.totalQuestions, 50);
        expect(parsedDocx.hasBlockingIssues, isFalse);

        final pdfBytes = await QuestionPaperPdfService.generate(
          exam: <String, dynamic>{
            'id': '2',
            'title': 'Finals',
            'subject_name': 'Information Assurance and Security',
            'assessment_type': 'final',
          },
          sections: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 1,
              'name': parsedDocx.sections.first.name,
              'question_type': 'multiple_choice',
              'section_order': 1,
              'default_points': 1.0,
            },
          ],
          questions: <int, List<Map<String, dynamic>>>{
            1: parsedDocx.sections.first.questions
                .map(
                  (q) => <String, dynamic>{
                    'id': q.questionNumber,
                    'question_number': q.questionNumber,
                    'question_text': q.questionText,
                    'points': q.points,
                    'choices': q.choices,
                  },
                )
                .toList(),
          },
        );

        final parsedPdf = QuestionPaperImportService.parseBytes(
          bytes: pdfBytes,
          fileName: 'filled_50_mc.pdf',
          expectedTemplate: mc50,
        );
        expect(parsedPdf.totalQuestions, 50);
        expect(parsedPdf.totalPoints, 50.0);
        expect(parsedPdf.hasBlockingIssues, isFalse);
        for (var i = 0; i < 50; i++) {
          final q = parsedPdf.sections.first.questions[i];
          expect(q.questionNumber, i + 1);
          expect(q.choices.length, 4);
          expect(q.choices[0], 'Option A for item ${i + 1}');
          expect(q.choices[3], 'Option D for item ${i + 1}');
        }
      },
    );

    test(
      '3. Mixed template (15 MC x 2 pts, 20 MC x 3 pts, 5 ID, 5 TF) preserves Part I A (1-15), Part I B (16-35), Part II (36-40), Part III (41-45), and 90-pt MC subtotal',
      () async {
        const mixedConfig = <QuestionnaireTemplateSectionConfig>[
          QuestionnaireTemplateSectionConfig(
            questionType: 'multiple_choice',
            itemCount: 15,
            pointsPerItem: 2,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'multiple_choice',
            itemCount: 20,
            pointsPerItem: 3,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'identification',
            itemCount: 5,
            pointsPerItem: 1,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'true_false',
            itemCount: 5,
            pointsPerItem: 1,
          ),
        ];

        final resolved = QuestionPaperImportService.resolveTemplateSections(
          mixedConfig,
        );
        expect(resolved.length, 4);
        expect(resolved[0].heading, 'Part I. Multiple Choice - A. 2 pts each');
        expect(resolved[0].startItem, 1);
        expect(resolved[0].endItem, 15);
        expect(resolved[1].heading, 'Part I. Multiple Choice - B. 3 pts each');
        expect(resolved[1].startItem, 16);
        expect(resolved[1].endItem, 35);
        expect(resolved[2].heading, 'Part II. Identification');
        expect(resolved[2].startItem, 36);
        expect(resolved[2].endItem, 40);
        expect(resolved[3].heading, 'Part III. True or False');
        expect(resolved[3].startItem, 41);
        expect(resolved[3].endItem, 45);

        final templateDocx = await QuestionPaperPdfService.generateTemplateDocx(
          sections: mixedConfig,
        );
        final filledDocx = _fillTemplateDocx(templateDocx);
        final parsedDocx = QuestionPaperImportService.parseBytes(
          bytes: filledDocx,
          fileName: 'mixed_45.docx',
        );

        // Export to PDF and re-parse without session state (simulating new session / device)
        final sectionMaps = <Map<String, dynamic>>[];
        final questionsBySec = <int, List<Map<String, dynamic>>>{};
        for (var i = 0; i < parsedDocx.sections.length; i++) {
          final s = parsedDocx.sections[i];
          final sid = i + 1;
          sectionMaps.add(<String, dynamic>{
            'id': sid,
            'name': s.name,
            'question_type': s.questionType,
            'section_order': sid,
            'default_points': s.defaultPoints,
          });
          questionsBySec[sid] = s.questions
              .map(
                (q) => <String, dynamic>{
                  'id': q.questionNumber,
                  'question_number': q.questionNumber,
                  'question_text': q.questionText,
                  'points': q.points,
                  'choices': q.choices,
                  'correct_answer': s.questionType == 'multiple_choice'
                      ? 'A'
                      : (s.questionType == 'true_false' ? 'True' : 'ANSWER'),
                },
              )
              .toList();
        }

        final pdfBytes = await QuestionPaperPdfService.generate(
          exam: <String, dynamic>{
            'id': '3',
            'title': 'Midterm Examination',
            'subject_name': 'Information Assurance and Security',
            'assessment_type': 'midterm',
          },
          sections: sectionMaps,
          questions: questionsBySec,
        );

        // Re-upload PDF without expectedTemplate (new session)
        final reuploaded = QuestionPaperImportService.parseBytes(
          bytes: pdfBytes,
          fileName: 'mixed_45_reuploaded.pdf',
        );
        expect(reuploaded.sections.length, 4);
        expect(
          reuploaded.sections[0].name,
          'Part I. Multiple Choice - A. 2 pts each',
        );
        expect(reuploaded.sections[0].startQuestionNumber, 1);
        expect(reuploaded.sections[0].endQuestionNumber, 15);
        expect(reuploaded.sections[0].defaultPoints, 2.0);
        expect(reuploaded.sections[0].totalPoints, 30.0);

        expect(
          reuploaded.sections[1].name,
          'Part I. Multiple Choice - B. 3 pts each',
        );
        expect(reuploaded.sections[1].startQuestionNumber, 16);
        expect(reuploaded.sections[1].endQuestionNumber, 35);
        expect(reuploaded.sections[1].defaultPoints, 3.0);
        expect(reuploaded.sections[1].totalPoints, 60.0);

        expect(reuploaded.sections[2].name, 'Part II. Identification');
        expect(reuploaded.sections[2].startQuestionNumber, 36);
        expect(reuploaded.sections[2].endQuestionNumber, 40);
        expect(reuploaded.sections[2].defaultPoints, 1.0);
        expect(reuploaded.sections[2].totalPoints, 5.0);

        expect(reuploaded.sections[3].name, 'Part III. True or False');
        expect(reuploaded.sections[3].startQuestionNumber, 41);
        expect(reuploaded.sections[3].endQuestionNumber, 45);
        expect(reuploaded.sections[3].defaultPoints, 1.0);
        expect(reuploaded.sections[3].totalPoints, 5.0);

        expect(reuploaded.pointsSubtotalByType['multiple_choice'], 90.0);
        expect(reuploaded.totalPoints, 100.0);
        expect(reuploaded.detectedAssessmentType, 'midterm');

        // Verify Answer Sheet PDF generation uses identical section order and numbering
        final answerSheetBytes = await AnswerSheetPdfService.generate(
          exam: <String, dynamic>{'id': '3', 'title': 'Midterm Examination'},
          sections: sectionMaps,
          questions: questionsBySec,
        );
        expect(answerSheetBytes, isNotEmpty);

        // Verify AssessmentValidator aggregates across repeated sections
        final validation = AssessmentValidator.validate(
          assessmentType: 'midterm',
          sections: sectionMaps,
          questionsBySectionId: questionsBySec,
        );
        expect(validation.isValid, isTrue);
      },
    );

    test(
      '4. Repeated True or False and Identification sections with different point values round-trip accurately',
      () async {
        const repeatedTfId = <QuestionnaireTemplateSectionConfig>[
          QuestionnaireTemplateSectionConfig(
            questionType: 'true_false',
            itemCount: 5,
            pointsPerItem: 1,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'true_false',
            itemCount: 5,
            pointsPerItem: 2,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'identification',
            itemCount: 5,
            pointsPerItem: 2,
          ),
          QuestionnaireTemplateSectionConfig(
            questionType: 'identification',
            itemCount: 5,
            pointsPerItem: 3,
          ),
        ];

        final templateDocx = await QuestionPaperPdfService.generateTemplateDocx(
          sections: repeatedTfId,
        );
        final filledDocx = _fillTemplateDocx(templateDocx);
        final parsed = QuestionPaperImportService.parseBytes(
          bytes: filledDocx,
          fileName: 'repeated_tf_id.docx',
        );

        expect(parsed.sections.length, 4);
        expect(parsed.sections[0].name, 'Part I. True or False - A. 1 pts each');
        expect(parsed.sections[1].name, 'Part I. True or False - B. 2 pts each');
        expect(
          parsed.sections[2].name,
          'Part II. Identification - A. 2 pts each',
        );
        expect(
          parsed.sections[3].name,
          'Part II. Identification - B. 3 pts each',
        );
        expect(parsed.pointsSubtotalByType['true_false'], 15.0);
        expect(parsed.pointsSubtotalByType['identification'], 25.0);
        expect(parsed.totalPoints, 40.0);
      },
    );

    test(
      '5. Missing choices, leftover placeholders, and mismatched counts are flagged before import',
      () {
        final rawText = [
          'Part I. Multiple Choice - A. 2 pts each',
          'A. (3 items x 2 points)',
          '1. [Write question here]',
          'A. [Write choice A here]',
          'B. Valid B',
          'C. Valid C',
          'D. Valid D',
          '2. Second question missing option D?',
          'A. Choice A',
          'B. Choice B',
          'C. Choice C',
        ].join('\n');

        final parsed = QuestionPaperImportService.parseBytes(
          bytes: Uint8List.fromList(utf8.encode(rawText)),
          fileName: 'incomplete.txt',
        );

        expect(parsed.hasBlockingIssues, isTrue);
        expect(
          parsed.issues.any((i) => i.kind == 'leftover_placeholder'),
          isTrue,
        );
        expect(
          parsed.issues.any((i) => i.kind == 'incomplete_choices'),
          isTrue,
        );
        expect(
          parsed.issues.any((i) => i.kind == 'mismatched_count'),
          isTrue,
        );
      },
    );
  });
}
