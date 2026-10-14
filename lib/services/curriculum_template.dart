import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Builds the downloadable Sample Guide (.xlsx) for uploading a curriculum.
///
/// Layout (one sheet):
///   Program / Curriculum
///   <Year Level>
///     <Semester>
///       Course Code | Course Name | Units
///       ...
///   LIST OF ELECTIVES
///     <classification name>
///       Course Code | Course Name | Units
///       ...
class CurriculumTemplate {
  static const String fileName = 'BSIT_2601.xlsx';

  static const String mimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  // style 0 = normal, 1 = bold
  static final List<_Row> _rows = [
    _Row(['Program', 'BSIT'], bold: true),
    _Row(['Curriculum', '2601'], bold: true),
    _Row(['Name this file Program_Curriculum (for example BSIT_2601.xlsx).']),
    _Row(['Repeat the year and semester blocks for every year level of the program.']),
    _Row(['Course Code and Course Name are required. Units is optional.']),
    _Row(['Leave Course Code blank only for an elective slot that has no code yet.']),
    _Row(['Do not add OJT or practicum subjects.']),
    _Row([]),
    _Row(['1st Year'], bold: true),
    _Row(['1st Semester'], bold: true),
    _Row(['Course Code', 'Course Name', 'Units'], bold: true),
    _Row(['CITE1004', 'Introduction to Computing', '3']),
    _Row(['CITE1003', 'Computer Programming 1', '3']),
    _Row(['GEDC1002', 'The Contemporary World', '3']),
    _Row(['STIC1002', 'Euthenics 1', '1']),
    _Row(['GEDC1016', 'Purposive Communication', '3']),
    _Row([]),
    _Row(['2nd Semester'], bold: true),
    _Row(['Course Code', 'Course Name', 'Units'], bold: true),
    _Row(['CITE1006', 'Computer Programming 2', '3']),
    _Row(['COSC1002', 'Discrete Structures 1 (Discrete Mathematics)', '3']),
    _Row(['GEDC1010', 'Art Appreciation', '3']),
    _Row(['INTE1006', 'Systems Administration and Maintenance', '3']),
    _Row([]),
    _Row(['2nd Year'], bold: true),
    _Row(['1st Semester'], bold: true),
    _Row(['Course Code', 'Course Name', 'Units'], bold: true),
    _Row(['COSC1003', 'Data Structures and Algorithms', '3']),
    _Row(['COSC1007', 'Human-Computer Interaction', '3']),
    _Row(['', 'IT Elective 1', '3']),
    _Row([]),
    _Row(['LIST OF ELECTIVES'], bold: true),
    _Row(['Application Development'], bold: true),
    _Row(['Course Code', 'Course Name', 'Units'], bold: true),
    _Row(['INTE1044', 'Object-Oriented Programming', '3']),
    _Row(['INTE1086', 'Enterprise Architecture', '3']),
    _Row(['Graphics Technology'], bold: true),
    _Row(['Course Code', 'Course Name', 'Units'], bold: true),
    _Row(['INTE1047', 'Introduction to Digital Graphics Design', '3']),
    _Row(['INTE1048', 'Introduction to Computer Animation', '3']),
  ];

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _col(int i) => String.fromCharCode(65 + i);

  static String _sheetXml() {
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
      ..write('<cols>')
      ..write('<col min="1" max="1" width="18" customWidth="1"/>')
      ..write('<col min="2" max="2" width="62" customWidth="1"/>')
      ..write('<col min="3" max="3" width="9" customWidth="1"/>')
      ..write('</cols><sheetData>');

    for (var r = 0; r < _rows.length; r++) {
      final row = _rows[r];
      if (row.cells.isEmpty) continue;
      b.write('<row r="${r + 1}">');
      for (var c = 0; c < row.cells.length; c++) {
        final v = row.cells[c];
        if (v.isEmpty) continue;
        final ref = '${_col(c)}${r + 1}';
        final style = row.bold ? ' s="1"' : '';
        final isNumber = c == 2 && RegExp(r'^\d+(\.\d+)?$').hasMatch(v) && !row.bold;
        if (isNumber) {
          b.write('<c r="$ref"$style><v>$v</v></c>');
        } else {
          b.write(
            '<c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${_esc(v)}</t></is></c>',
          );
        }
      }
      b.write('</row>');
    }
    b.write('</sheetData></worksheet>');
    return b.toString();
  }

  static const String _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '</Types>';

  static const String _rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';

  static const String _workbook =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="Curriculum" sheetId="1" r:id="rId1"/></sheets></workbook>';

  static const String _workbookRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';

  static const String _styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
      '</styleSheet>';

  static void _add(Archive archive, String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  /// The .xlsx file as bytes.
  static Uint8List buildXlsx() {
    final archive = Archive();
    _add(archive, '[Content_Types].xml', _contentTypes);
    _add(archive, '_rels/.rels', _rootRels);
    _add(archive, 'xl/workbook.xml', _workbook);
    _add(archive, 'xl/_rels/workbook.xml.rels', _workbookRels);
    _add(archive, 'xl/styles.xml', _styles);
    _add(archive, 'xl/worksheets/sheet1.xml', _sheetXml());

    final List<int>? encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded ?? const <int>[]);
  }
}

class _Row {
  _Row(this.cells, {this.bold = false});
  final List<String> cells;
  final bool bold;
}
