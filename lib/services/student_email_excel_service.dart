import 'dart:typed_data';

import 'student_import_service.dart' show XlsxIO, XlsxCell, XlsxStyle;

/// Represents one row from a Student Emails Excel workbook.
class StudentEmailExcelRow {
  const StudentEmailExcelRow({
    required this.studentNumber,
    required this.name,
    required this.email,
  });

  final String studentNumber;
  final String name;
  final String email;
}

/// Creates and reads Excel templates for bulk student email updates.
class StudentEmailExcelService {
  static List<int> buildTemplate({
    required List<Map<String, dynamic>> entries,
  }) {
    final rows = <List<XlsxCell?>>[
      [
        const XlsxCell('Student No.', XlsxStyle.header),
        const XlsxCell('Name', XlsxStyle.header),
        const XlsxCell('Email Username', XlsxStyle.header),
      ],
    ];

    for (final entry in entries) {
      final controller = entry['controller'] as dynamic;

      rows.add([
        XlsxCell(
          entry['student_number']?.toString() ?? '',
          XlsxStyle.textColumn,
        ),
        XlsxCell(entry['name']?.toString() ?? ''),
        XlsxCell(controller.text.toString()),
      ]);
    }

    return XlsxIO.writeGrid(
      sheetName: 'Student Emails',
      rows: rows,
      widths: const [20, 40, 38],
      columnStyles: const {0: XlsxStyle.textColumn},
    );
  }

  static List<StudentEmailExcelRow> parse(Uint8List bytes) {
    final rows = XlsxIO.readRows(bytes);

    if (rows.isEmpty) {
      throw const FormatException('The Excel file is empty.');
    }

    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    final headerIndex = rows.indexWhere((row) {
      final headers = row.map(normalize).toSet();

      return headers.contains('studentno') &&
          headers.contains('name') &&
          headers.contains('emailusername');
    });

    if (headerIndex < 0) {
      throw const FormatException(
        'Required columns: Student No., Name, and Email Username.',
      );
    }

    final headers = rows[headerIndex].map(normalize).toList();

    final numberColumn = headers.indexOf('studentno');
    final nameColumn = headers.indexOf('name');
    final emailColumn = headers.indexOf('emailusername');

    String cell(List<String> row, int index) =>
        index < row.length ? row[index].trim() : '';

    final result = <StudentEmailExcelRow>[];

    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];

      final number = cell(row, numberColumn);
      final name = cell(row, nameColumn);
      final email = cell(row, emailColumn);

      if (number.isEmpty && name.isEmpty && email.isEmpty) {
        continue;
      }

      if (number.isEmpty) {
        continue;
      }

      result.add(
        StudentEmailExcelRow(studentNumber: number, name: name, email: email),
      );
    }

    if (result.isEmpty) {
      throw const FormatException(
        'The Excel file contains no student records.',
      );
    }

    return result;
  }
}
