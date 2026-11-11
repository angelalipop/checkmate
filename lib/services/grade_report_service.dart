import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Grade reports consume the complete saved scorebook, never a filtered UI tab.
class GradeReportService {
  static const periods = {
    'prelims': 'Prelims',
    'midterm': 'Midterm',
    'pre_finals': 'Pre-Finals',
    'finals': 'Finals',
  };
  static const categories = {
    'pt': 'Performance Tasks / Laboratory',
    'quiz': 'Quizzes',
    'exam': 'Major Examination',
  };
  static List<Map<String, dynamic>> _maps(Object? v) => v is List
      ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
      : [];
  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : {};
  static String _name(Map<String, dynamic> s) =>
      '${s['last_name'] ?? ''}, ${s['first_name'] ?? ''}';
  static String _text(Object? n) => n is num ? n.toStringAsFixed(2) : 'INC';
  static Map<String, dynamic> _cell(Map<String, dynamic> s, Object? id) =>
      _maps(s['cells']).where((c) => c['exam_id'] == id).firstOrNull ?? {};
  static Map<String, dynamic> _grade(Map<String, dynamic> s, String p) =>
      _map(_map(s['grading'])[p]);
  static List<Map<String, dynamic>> _assessments(
    Map<String, dynamic> book,
    String period,
  ) {
    final list = _maps(book['assessments'])
        .where((a) => a['grading_period'] == period)
        .toList();
    const rank = {'pt': 0, 'quiz': 1, 'exam': 2};
    list.sort((a, b) {
      final n = (rank[a['grading_category']] ?? 3).compareTo(
        rank[b['grading_category']] ?? 3,
      );
      return n != 0 ? n : (a['id'] as num).compareTo(b['id'] as num);
    });
    return list;
  }

  static Future<Uint8List> pdf({
    required Map<String, dynamic> book,
    required String title,
    required String section,
    Map<String, dynamic>? student,
    Uint8List? fontRegular,
    Uint8List? fontBold,
  }) async {
    final doc = pw.Document(
      theme: fontRegular == null
          ? null
          : pw.ThemeData.withFont(
              base: pw.Font.ttf(fontRegular.buffer.asByteData()),
              bold: pw.Font.ttf((fontBold ?? fontRegular).buffer.asByteData()),
            ),
    );
    final weights = _map(book['preferences']);
    pw.Widget heading(String heading) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          heading,
          style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.Text(title, style: const pw.TextStyle(fontSize: 11)),
        pw.Text(section, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 14),
      ],
    );
    if (student != null) {
      final grading = _map(student['grading']);
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (_) => [
            heading('Student Grade Information'),
            pw.Text(
              _name(student),
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('Student No. ${student['student_number'] ?? ''}'),
            pw.SizedBox(height: 16),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              color: PdfColors.blue50,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Final Grade: ${_text(grading['final_grade'])}'),
                  pw.Text('Status: ${grading['status'] ?? 'INC'}'),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              headers: [
                'Grading Period',
                'PT / LAB\n${weights['pt']}%',
                'Quizzes\n${weights['quiz']}%',
                'Major Exam\n${weights['exam']}%',
                'Period Grade',
                'Weighted Contribution',
              ],
              data: [
                for (final p in periods.entries)
                  [
                    '${p.value}\n${weights[p.key]}%',
                    for (final k in categories.keys)
                      _text(
                        _map(
                          _map(_grade(student, p.key)['categories'])[k],
                        )['percentage'],
                      ),
                    _text(_grade(student, p.key)['grade']),
                    _text(_grade(student, p.key)['contribution']),
                  ],
              ],
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.all(7),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue50),
              border: pw.TableBorder.all(color: PdfColors.blueGrey200),
            ),
            pw.SizedBox(height: 12),
            pw.Text(
              'Interim contribution (completed periods, without normalization): ${_text(grading['interim_contribution'])}',
              style: const pw.TextStyle(fontSize: 9),
            ),
            if (grading['requires_classification'] == true)
              pw.Text(
                'INC: historical assessments require teacher classification.',
                style: const pw.TextStyle(fontSize: 9),
              ),
          ],
        ),
      );
    } else {
      final students = _maps(book['students']);
      for (final p in periods.entries) {
        final items = _assessments(book, p.key);
        // Horizontal bands preserve readable type while allowing unlimited columns.
        const bandSize = 7;
        final bands = math.max(1, (items.length / bandSize).ceil());
        for (var band = 0; band < bands; band++) {
          final chunk = items.skip(band * bandSize).take(bandSize).toList();
          doc.addPage(
            pw.MultiPage(
              pageFormat: PdfPageFormat.a4.landscape,
              margin: const pw.EdgeInsets.all(22),
              maxPages: 10000,
              header: (_) => pw.Column(
                children: [
                  heading('Whole-Section Grade Report'),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.all(7),
                    color: PdfColors.blueGrey800,
                    child: pw.Text(
                      '${p.value.toUpperCase()} · ${weights[p.key]}% · Assessment band ${band + 1}/$bands',
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 5),
                  pw.Text(
                    'Performance Tasks / Laboratory ${weights['pt']}%     Quizzes ${weights['quiz']}%     Major Examination ${weights['exam']}%',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                  pw.SizedBox(height: 8),
                ],
              ),
              footer: (c) => pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  'Page ${c.pageNumber}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ),
              build: (_) => [
                pw.TableHelper.fromTextArray(
                  headers: [
                    'Student No.',
                    'Student Name',
                    for (final a in chunk)
                      '${a['column_label']}\nMax ${a['total_points']}${a['grade_eligible'] == true ? '' : '\nDraft'}',
                    'PT / LAB\n${weights['pt']}%',
                    'Quizzes\n${weights['quiz']}%',
                    'Exam\n${weights['exam']}%',
                    'Period Grade',
                  ],
                  data: [
                    for (final s in students)
                      [
                        '${s['student_number'] ?? ''}',
                        _name(s),
                        for (final a in chunk) _scoreText(_cell(s, a['id'])),
                        for (final k in categories.keys)
                          _text(
                            _map(
                              _map(_grade(s, p.key)['categories'])[k],
                            )['percentage'],
                          ),
                        _text(_grade(s, p.key)['grade']),
                      ],
                  ],
                  headerStyle: pw.TextStyle(
                    fontSize: 7,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  cellStyle: const pw.TextStyle(fontSize: 7),
                  cellPadding: const pw.EdgeInsets.all(4),
                  headerDecoration: const pw.BoxDecoration(
                    color: PdfColors.blue50,
                  ),
                  border: pw.TableBorder.all(color: PdfColors.blueGrey300),
                  columnWidths: {
                    0: const pw.FixedColumnWidth(63),
                    1: const pw.FixedColumnWidth(130),
                    for (var i = 0; i < chunk.length; i++)
                      i + 2: const pw.FlexColumnWidth(),
                    for (var i = 0; i < 4; i++)
                      chunk.length + 2 + i: const pw.FixedColumnWidth(55),
                  },
                ),
                pw.SizedBox(height: 10),
                for (final a in chunk)
                  pw.Text(
                    '${a['column_label']}: ${a['title']} — ${a['grade_eligible'] == true ? 'included' : 'draft, excluded from grades'}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'Pending and review scores are incomplete. Recorded zero remains valid. Score/max is printed when an attempt has a different maximum.',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ],
            ),
          );
        }
      }
      final unknown = _maps(book['assessments'])
          .where((a) => a['grading_period'] == null)
          .toList();
      if (unknown.isNotEmpty)
        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4.landscape,
            build: (_) => [
              heading('Historical Assessments — Needs Classification'),
              pw.TableHelper.fromTextArray(
                headers: [
                  'Student No.',
                  'Name',
                  for (final a in unknown)
                    '${a['title']} / ${a['total_points']}',
                ],
                data: [
                  for (final s in students)
                    [
                      '${s['student_number']}',
                      _name(s),
                      for (final a in unknown) _scoreText(_cell(s, a['id'])),
                    ],
                ],
                cellStyle: const pw.TextStyle(fontSize: 7),
              ),
            ],
          ),
        );
    }
    return doc.save();
  }

  static String _scoreText(Map<String, dynamic> c) {
    if (c['score'] == null) return c['status'] == 'absent' ? 'Absent' : '—';
    return '${_text(c['score'])}/${_text(c['max_score'])}${c['status'] == 'completed' ? '' : ' (review)'}';
  }

  /// Genuine multi-sheet OOXML workbook. Formula caches mirror saved grades;
  /// Excel recalculates after score edits. Blank scores are never coerced to zero.
  static Uint8List xlsx({
    required Map<String, dynamic> book,
    required String title,
    required String section,
    Map<String, dynamic>? student,
  }) {
    final people = student == null ? _maps(book['students']) : [student];
    final weights = _map(book['preferences']);
    final sheets = <_GradeSheet>[];
    final periodGradeColumns = <String, int>{};
    final summary = _GradeSheet('Grade Summary');
    summary.rows.add([_XCell(title, style: 1), _XCell(section)]);
    summary.rows.add([
      _XCell('Category weights'),
      for (final k in categories.keys)
        _XCell('${categories[k]}: ${weights[k]}%'),
    ]);
    summary.rows.add([
      _XCell('Student No.', style: 1),
      _XCell('Student Name', style: 1),
      for (final p in periods.entries)
        _XCell('${p.value} (${weights[p.key]}%)', style: 1),
      _XCell('Final Grade', style: 1),
      _XCell('Status', style: 1),
      _XCell('Interim Contribution', style: 1),
    ]);
    sheets.add(summary);
    for (final p in periods.entries) {
      final sh = _GradeSheet(p.value);
      final items = _assessments(book, p.key);
      sh.rows.add([_XCell(title, style: 1), _XCell('$section · ${p.value}')]);
      final groups = <_XCell>[_XCell(''), _XCell('')];
      final headers = <_XCell>[
        _XCell('Student No.', style: 1),
        _XCell('Student Name', style: 1),
      ];
      final details = <_XCell>[_XCell(''), _XCell('Maximum / inclusion')];
      final colById = <Object?, int>{};
      final categoryCols = <String, int>{};
      int column = 2;
      for (final k in [...categories.keys, 'unknown']) {
        final groupStart = column;
        for (final a in items.where(
          (a) => (a['grading_category'] ?? 'unknown') == k,
        )) {
          colById[a['id']] = column;
          groups.addAll([
            _XCell(categories[k] ?? 'Unclassified', style: 1),
            _XCell(''),
            _XCell(''),
            _XCell(''),
          ]);
          headers.addAll([
            _XCell('${a['column_label']} · ${a['title']}', style: 1),
            _XCell('Maximum', style: 1),
            _XCell('Status', style: 1),
            _XCell('Percentage', style: 1),
          ]);
          details.addAll([
            _XCell(a['total_points']),
            _XCell(''),
            _XCell(a['grade_eligible'] == true ? 'Included' : 'Excluded draft'),
            _XCell(''),
          ]);
          column += 4;
        }
        if (k != 'unknown') {
          categoryCols[k] = column;
          groups.add(_XCell('${categories[k]} · ${weights[k]}%', style: 1));
          headers.add(_XCell('Category Total %', style: 1));
          details.add(_XCell('Equal assessment weights'));
          column++;
          sh.merges.add('${_col(groupStart)}2:${_col(column - 1)}2');
        }
      }
      final gradeColumn = column;
      periodGradeColumns[p.key] = gradeColumn;
      groups.addAll([
        _XCell('Period', style: 1),
        _XCell('Contribution', style: 1),
      ]);
      headers.addAll([
        _XCell('Period Grade', style: 1),
        _XCell('Weighted Contribution', style: 1),
      ]);
      details.addAll([_XCell(''), _XCell('${weights[p.key]}%')]);
      sh.rows.addAll([groups, headers, details]);
      for (var i = 0; i < people.length; i++) {
        final s = people[i];
        final rowNumber = i + 5;
        final row = List<_XCell>.generate(column + 2, (_) => _XCell(''));
        row[0] = _XCell('${s['student_number'] ?? ''}');
        row[1] = _XCell(_name(s));
        for (final a in items) {
          final col = colById[a['id']]!;
          final c = _cell(s, a['id']);
          row[col] = _XCell(c['score']);
          row[col + 1] = _XCell(c['max_score'] ?? a['total_points']);
          row[col + 2] = _XCell(c['status'] ?? 'pending');
          final score = '${_col(col)}$rowNumber',
              max = '${_col(col + 1)}$rowNumber',
              status = '${_col(col + 2)}$rowNumber';
          row[col + 3] = _XCell.formula(
            'IF(AND(ISNUMBER($score),ISNUMBER($max),$max>0,$status="completed"),$score/$max*100,"INC")',
            c['status'] == 'completed' &&
                    c['score'] is num &&
                    c['max_score'] is num &&
                    (c['max_score'] as num) > 0
                ? (c['score'] as num) / (c['max_score'] as num) * 100
                : 'INC',
          );
        }
        for (final k in categories.keys) {
          final included = items
              .where(
                (a) =>
                    a['grading_category'] == k && a['grade_eligible'] == true,
              )
              .toList();
          final refs = [
            for (final a in included)
              '${_col(colById[a['id']]! + 3)}$rowNumber',
          ];
          final formula = refs.isEmpty
              ? '"INC"'
              : 'IF(COUNT(${refs.join(',')})=${refs.length},AVERAGE(${refs.join(',')}),"INC")';
          row[categoryCols[k]!] = _XCell.formula(
            formula,
            _map(_map(_grade(s, p.key)['categories'])[k])['percentage'] ??
                'INC',
          );
        }
        final positive = categories.keys
            .where((k) => (weights[k] as num) > 0)
            .toList();
        final refs = [
          for (final k in positive) '${_col(categoryCols[k]!)}$rowNumber',
        ];
        final weighted = [
          for (final k in positive)
            '${_col(categoryCols[k]!)}$rowNumber*${weights[k]}/100',
        ];
        row[gradeColumn] = _XCell.formula(
          'IF(COUNT(${refs.join(',')})=${refs.length},${weighted.join('+')},"INC")',
          _grade(s, p.key)['grade'] ?? 'INC',
        );
        final gr = '${_col(gradeColumn)}$rowNumber';
        row[gradeColumn + 1] = _XCell.formula(
          (weights[p.key] as num) == 0
              ? '0'
              : 'IF(ISNUMBER($gr),$gr*${weights[p.key]}/100,"INC")',
          _grade(s, p.key)['contribution'] ?? 'INC',
        );
        sh.rows.add(row);
      }
      sheets.add(sh);
    }
    for (var i = 0; i < people.length; i++) {
      final s = people[i], grading = _map(people[i]['grading']);
      final r = i + 5;
      final row = <_XCell>[
        _XCell('${s['student_number'] ?? ''}'),
        _XCell(_name(s)),
      ];
      final refs = <String>[];
      for (final p in periods.entries) {
        final ref = "'${p.value}'!${_col(periodGradeColumns[p.key]!)}$r";
        row.add(_XCell.formula(ref, _grade(s, p.key)['grade'] ?? 'INC'));
        if ((weights[p.key] as num) > 0)
          refs.add('${_col(row.length - 1)}${i + 4}');
      }
      final summaryRow = i + 4;
      final terms = [
        for (var j = 0; j < periods.length; j++)
          if ((weights[periods.keys.elementAt(j)] as num) > 0)
            '${_col(j + 2)}$summaryRow*${weights[periods.keys.elementAt(j)]}/100',
      ];
      final unknown = grading['requires_classification'] == true;
      row.add(
        _XCell.formula(
          unknown
              ? '"INC"'
              : 'IF(COUNT(${refs.join(',')})=${refs.length},${terms.join('+')},"INC")',
          grading['final_grade'] ?? 'INC',
        ),
      );
      row.add(
        _XCell.formula(
          'IF(ISNUMBER(G$summaryRow),"Recorded","INC")',
          grading['status'] ?? 'INC',
        ),
      );
      row.add(_XCell(grading['interim_contribution'] ?? 'INC'));
      summary.rows.add(row);
    }
    // Keep unclassified historical scores in the exported workbook too.
    final unknown = _maps(book['assessments'])
        .where((a) => a['grading_period'] == null)
        .toList();
    if (unknown.isNotEmpty) {
      final sh = _GradeSheet('Needs Classification');
      sh.rows.add([
        for (final h in [
          'Student No.',
          'Student Name',
          'Assessment ID',
          'Assessment',
          'Score',
          'Maximum',
          'Status',
        ])
          _XCell(h, style: 1),
      ]);
      for (final s in people) {
        for (final a in unknown) {
          final c = _cell(s, a['id']);
          sh.rows.add([
            _XCell('${s['student_number']}'),
            _XCell(_name(s)),
            _XCell(a['id']),
            _XCell(a['title']),
            _XCell(c['score']),
            _XCell(c['max_score']),
            _XCell(c['status']),
          ]);
        }
      }
      sheets.add(sh);
    }
    return _workbook(sheets);
  }

  static String _col(int index) {
    var n = index + 1;
    var result = '';
    while (n > 0) {
      n--;
      result = String.fromCharCode(65 + n % 26) + result;
      n ~/= 26;
    }
    return result;
  }

  static String _xml(Object? value) => '${value ?? ''}'
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static Uint8List _workbook(List<_GradeSheet> sheets) {
    final archive = Archive();
    void add(String name, String content) {
      final data = utf8.encode(content);
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    const ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${[for (var i = 0; i < sheets.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}</Types>',
    );
    add(
      '_rels/.rels',
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    );
    add(
      'xl/workbook.xml',
      '<?xml version="1.0"?><workbook xmlns="$ns" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_xml(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>',
    );
    add(
      'xl/_rels/workbook.xml.rels',
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    );
    add(
      'xl/styles.xml',
      '<?xml version="1.0"?><styleSheet xmlns="$ns"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD8E4F3"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
    );
    for (var i = 0; i < sheets.length; i++) {
      final sh = sheets[i];
      final out = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="$ns"><sheetViews><sheetView workbookViewId="0"><pane xSplit="2" ySplit="${i == 0 ? 3 : 4}" topLeftCell="C${i == 0 ? 4 : 5}" activePane="bottomRight" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="20" customWidth="1"/><col min="2" max="2" width="38" customWidth="1"/><col min="3" max="16384" width="19" customWidth="1"/></cols><sheetData>',
      );
      for (var r = 0; r < sh.rows.length; r++) {
        out.write(
          '<row r="${r + 1}"${r < 4 ? ' ht="34" customHeight="1"' : ''}>',
        );
        final cells = sh.rows[r];
        for (var c = 0; c < cells.length; c++) {
          final cell = cells[c];
          final ref = '${_col(c)}${r + 1}';
          final value = cell.value;
          if (cell.formula != null) {
            out.write(
              '<c r="$ref" s="2"${value is num ? '' : ' t="str"'}><f>${_xml(cell.formula)}</f><v>${_xml(value)}</v></c>',
            );
          } else if (value is num) {
            out.write(
              '<c r="$ref" s="${cell.style == 1 ? 1 : 2}"><v>$value</v></c>',
            );
          } else {
            out.write(
              '<c r="$ref" s="${cell.style}" t="inlineStr"><is><t xml:space="preserve">${_xml(value)}</t></is></c>',
            );
          }
        }
        out.write('</row>');
      }
      out.write('</sheetData>');
      final merges = sh.merges
          .where((m) => m.split(':').first != m.split(':').last)
          .toList();
      if (merges.isNotEmpty)
        out.write(
          '<mergeCells count="${merges.length}">${merges.map((m) => '<mergeCell ref="$m"/>').join()}</mergeCells>',
        );
      out.write(
        '<pageSetup orientation="landscape" paperSize="9"/></worksheet>',
      );
      add('xl/worksheets/sheet${i + 1}.xml', out.toString());
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

class _XCell {
  _XCell(this.value, {this.style = 0}) : formula = null;
  _XCell.formula(this.formula, this.value) : style = 2;
  final Object? value;
  final int style;
  final String? formula;
}

class _GradeSheet {
  _GradeSheet(this.name);
  final String name;
  final rows = <List<_XCell>>[];
  final merges = <String>[];
}
