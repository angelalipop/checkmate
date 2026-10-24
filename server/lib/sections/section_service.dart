import 'package:postgres/postgres.dart';

import 'package:server/database.dart';

class SectionService {
  static const _select = '''
    SELECT s.id, s.name, s.program_id, p.code, p.level,
           s.year_level, s.school_year, s.semester, s.created_at
    FROM sections s
    JOIN academic_programs p ON p.id = s.program_id
  ''';

  static Map<String, dynamic> _json(ResultRow r) => {
        'id': r[0],
        'name': r[1],
        'program_id': r[2],
        'program_code': r[3],
        'program_level': r[4],
        'year_level': r[5],
        'school_year': r[6],
        'semester': r[7],
        'created_at': r[8].toString(),
      };

  static Future<List<Map<String, dynamic>>> getAll() async {
    final result = await Database.pool.execute(
      Sql.named('$_select ORDER BY p.code, s.year_level, s.name'),
    );
    return result.map(_json).toList();
  }

  /// Throws [ArgumentError] (message is safe to show) on bad input.
  static Future<Map<String, dynamic>> create({
    required int programId,
    required String name,
    required int yearLevel,
    required String schoolYear,
    required int semester,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('Section name is required.');
    if (!RegExp(r'^\d{4}-\d{4}$').hasMatch(schoolYear)) {
      throw ArgumentError('School year must look like 2026-2027.');
    }
    if (semester != 1 && semester != 2) {
      throw ArgumentError('Semester must be 1 or 2.');
    }

    final program = await Database.pool.execute(
      Sql.named('''
        SELECT level FROM academic_programs
        WHERE id = @id AND is_deleted = FALSE
      '''),
      parameters: {'id': programId},
    );
    if (program.isEmpty) throw ArgumentError('Program or strand not found.');

    final maxYear = program.first[0] == 'shs' ? 2 : 4;
    if (yearLevel < 1 || yearLevel > maxYear) {
      throw ArgumentError('Year level must be between 1 and $maxYear.');
    }

    final inserted = await Database.pool.execute(
      Sql.named('''
        INSERT INTO sections
          (program_id, name, year_level, school_year, semester)
        VALUES (@program_id, @name, @year_level, @school_year, @semester)
        RETURNING id
      '''),
      parameters: {
        'program_id': programId,
        'name': cleanName,
        'year_level': yearLevel,
        'school_year': schoolYear,
        'semester': semester,
      },
    );

    final row = await Database.pool.execute(
      Sql.named('$_select WHERE s.id = @id'),
      parameters: {'id': inserted.first[0]},
    );
    return _json(row.first);
  }

  /// Creates all [names] in one transaction: if any name already exists,
  /// nothing is saved. Throws [ArgumentError] on bad input.
  static Future<List<Map<String, dynamic>>> createMany({
    required int programId,
    required List<String> names,
    required int yearLevel,
    required String schoolYear,
    required int semester,
  }) async {
    final cleanNames = names.map((e) => e.trim()).where((e) => e.isNotEmpty);
    final unique = cleanNames.toSet().toList();
    if (unique.isEmpty) throw ArgumentError('At least one section is required.');
    if (unique.length > 26) throw ArgumentError('Too many sections at once.');
    if (!RegExp(r'^\d{4}-\d{4}$').hasMatch(schoolYear)) {
      throw ArgumentError('School year must look like 2026-2027.');
    }
    if (semester != 1 && semester != 2) {
      throw ArgumentError('Semester must be 1 or 2.');
    }

    final program = await Database.pool.execute(
      Sql.named('''
        SELECT level FROM academic_programs
        WHERE id = @id AND is_deleted = FALSE
      '''),
      parameters: {'id': programId},
    );
    if (program.isEmpty) throw ArgumentError('Program or strand not found.');

    final maxYear = program.first[0] == 'shs' ? 2 : 4;
    if (yearLevel < 1 || yearLevel > maxYear) {
      throw ArgumentError('Year level must be between 1 and $maxYear.');
    }

    final ids = await Database.pool.runTx((tx) async {
      final out = <Object?>[];
      for (final name in unique) {
        final r = await tx.execute(
          Sql.named('''
            INSERT INTO sections
              (program_id, name, year_level, school_year, semester)
            VALUES (@program_id, @name, @year_level, @school_year, @semester)
            RETURNING id
          '''),
          parameters: {
            'program_id': programId,
            'name': name,
            'year_level': yearLevel,
            'school_year': schoolYear,
            'semester': semester,
          },
        );
        out.add(r.first[0]);
      }
      return out;
    });

    final rows = await Database.pool.execute(
      Sql.named('$_select WHERE s.id = ANY(@ids) ORDER BY s.name'),
      parameters: {'ids': TypedValue(Type.integerArray, ids)},
    );
    return rows.map(_json).toList();
  }
}
