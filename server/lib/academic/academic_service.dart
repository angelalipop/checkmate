import 'package:postgres/postgres.dart';

import 'package:server/academic/academic_exception.dart';
import 'package:server/database.dart';

export 'package:server/academic/academic_exception.dart';

/// Academic Management: programs, curricula, curriculum subjects, the list
/// of electives and the elective finalized per school year.
///
/// Deleted records remain in PostgreSQL with is_deleted / deleted_at /
/// deleted_by set. Every normal query filters on is_deleted = FALSE.
class AcademicService {
  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------

  static final RegExp _programCode = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9 _-]{1,19}$',
  );
  static final RegExp _curriculumCode = RegExp(r'^[0-9A-Za-z-]{2,20}$');
  static final RegExp _courseCode = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9 ._/-]{1,29}$',
  );
  static final RegExp _schoolYear = RegExp(r'^[0-9]{4}-[0-9]{4}$');

  /// OJT / practicum / internship / work immersion are not added.
  static final RegExp _ojtLike = RegExp(
    r'^OJTC|practicum|internship|on[- ]the[- ]job|\bOJT\b|work immersion',
    caseSensitive: false,
  );

  static int _int(Object? v) => (v! as num).toInt();

  static String _text(Object? v) => v?.toString().trim() ?? '';

  static String? _textOrNull(Object? v) {
    final s = _text(v);
    return s.isEmpty ? null : s;
  }

  /// Translates database errors into friendly messages.
  static Object mapError(Object e) {
    if (e is AcademicException) return e;

    if (e is ServerException) {
      switch (e.code) {
        case '23505':
          return AcademicException(
            'That record already exists.',
            statusCode: 409,
          );
        case '23503':
          return AcademicException(
            'That record is still in use and cannot be changed.',
            statusCode: 409,
          );
        case '23514':
          return AcademicException(
            'A value breaks a database rule. Check the entries and try again.',
          );
        case 'P0001':
          return AcademicException(e.message, statusCode: 409);
      }
    }

    return e;
  }

  static Future<T> _tx<T>(Future<T> Function(TxSession tx) body) async {
    try {
      return await Database.pool.runTx(body);
    } catch (e) {
      final mapped = mapError(e);
      if (mapped is AcademicException) throw mapped;
      rethrow;
    }
  }

  static int? _hoursInput(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final v = int.tryParse(text);
    if (v == null || v < 0 || v > 1000) {
      throw AcademicException('Required hours must be a whole number.');
    }
    return v;
  }

  static int _year(Object? raw) {
    final v = int.tryParse(raw?.toString() ?? '');
    if (v == null || v < 1 || v > 4) {
      throw AcademicException('Year level must be 1 to 4.');
    }
    return v;
  }

  static int _term(Object? raw) {
    final v = int.tryParse(raw?.toString() ?? '');
    if (v == null || v < 1 || v > 2) {
      throw AcademicException('Semester must be 1 or 2.');
    }
    return v;
  }

  static String _validateSchoolYear(Object? raw) {
    final v = _text(raw);
    if (!_schoolYear.hasMatch(v)) {
      throw AcademicException('School year must look like 2025-2026.');
    }
    final a = int.parse(v.substring(0, 4));
    final b = int.parse(v.substring(5));
    if (b != a + 1) {
      throw AcademicException('School year must span consecutive years.');
    }
    return v;
  }

  /// Archives a row while preserving it in PostgreSQL.
  static Future<void> _remove(
    Session s,
    String table,
    String where,
    Map<String, Object?> params,
    int? actor,
  ) async {
    await s.execute(
      Sql.named('''
        UPDATE $table
        SET is_deleted = TRUE, deleted_at = NOW(),
            deleted_by = @actor, updated_at = NOW()
        WHERE $where AND is_deleted = FALSE
      '''),
      parameters: {...params, 'actor': actor},
    );
  }

  // ------------------------------------------------------------------
  // programs
  // ------------------------------------------------------------------

  static Map<String, dynamic> _programJson(ResultRow r) => {
    'id': _int(r[0]),
    'code': r[1],
    'name': r[2],
    'level': r[3],
    'department': r[4],
    'curriculum_count': _int(r[5]),
    'published_curriculum': r[6],
  };

  static const _programSelect = '''
    SELECT p.id, p.code, p.name, p.level, p.department,
      (SELECT COUNT(*) FROM curricula c
        WHERE c.program_id = p.id AND c.is_deleted = FALSE)::int,
      (SELECT c.code FROM curricula c
        WHERE c.program_id = p.id AND c.is_deleted = FALSE
          AND c.status = 'published'
        ORDER BY c.code DESC LIMIT 1)
    FROM academic_programs p
  ''';

  /// Lists active academic programs.
  static Future<List<Map<String, dynamic>>> listPrograms({String? q}) async {
    final term = _textOrNull(q);
    final result = await Database.pool.execute(
      Sql.named('''
        $_programSelect
        WHERE p.is_deleted = FALSE
          AND (@q::text IS NULL
               OR p.code ILIKE '%' || @q::text || '%'
               OR p.name ILIKE '%' || @q::text || '%'
               OR COALESCE(p.department, '') ILIKE '%' || @q::text || '%')
        ORDER BY p.level DESC, p.department NULLS LAST, p.code
      '''),
      parameters: {'q': term},
    );
    return result.map(_programJson).toList();
  }

  static Future<Map<String, dynamic>> _programById(Session s, int id) async {
    final result = await s.execute(
      Sql.named('$_programSelect WHERE p.id = @id AND p.is_deleted = FALSE'),
      parameters: {'id': id},
    );
    if (result.isEmpty) {
      throw AcademicException('Program not found.', statusCode: 404);
    }
    return _programJson(result.first);
  }

  static ({String code, String name, String level, String? department})
  _programInput(Map<String, dynamic> body) {
    final code = _text(body['code']).toUpperCase();
    final name = _text(body['name']);
    final level = _text(body['level']).toLowerCase();
    final department = _textOrNull(body['department']);

    if (!_programCode.hasMatch(code)) {
      throw AcademicException(
        'Program code must be 2 to 20 letters or numbers (e.g. BSIT, STEM).',
      );
    }
    if (name.isEmpty || name.length > 200) {
      throw AcademicException('Program name is required.');
    }
    if (level != 'college' && level != 'shs') {
      throw AcademicException('Choose College or Senior High School.');
    }
    return (
      code: code,
      name: name,
      level: level,
      department: level == 'college' ? department : null,
    );
  }

  static Future<void> _assertProgramCodeFree(
    Session s,
    String code, {
    int excludeId = -1,
  }) async {
    final dup = await s.execute(
      Sql.named('''
        SELECT 1 FROM academic_programs
        WHERE UPPER(code) = @code AND is_deleted = FALSE AND id <> @id
      '''),
      parameters: {'code': code, 'id': excludeId},
    );
    if (dup.isNotEmpty) {
      throw AcademicException(
        'A program with code $code already exists.',
        statusCode: 409,
      );
    }
  }

  /// Creates an academic program.
  static Future<Map<String, dynamic>> createProgram(
    Map<String, dynamic> body,
  ) async {
    final input = _programInput(body);

    return _tx((tx) async {
      await _assertProgramCodeFree(tx, input.code);

      final created = await tx.execute(
        Sql.named('''
          INSERT INTO academic_programs (code, name, level, department)
          VALUES (@code, @name, @level, @department)
          RETURNING id
        '''),
        parameters: {
          'code': input.code,
          'name': input.name,
          'level': input.level,
          'department': input.department,
        },
      );
      return _programById(tx, _int(created.first[0]));
    });
  }

  /// Updates an academic program.
  static Future<Map<String, dynamic>> updateProgram(
    int id,
    Map<String, dynamic> body,
  ) async {
    final input = _programInput(body);

    return _tx((tx) async {
      final current = await _programById(tx, id);
      await _assertProgramCodeFree(tx, input.code, excludeId: id);

      if (current['level'] != input.level &&
          _int(current['curriculum_count']) > 0) {
        throw AcademicException(
          'The level cannot change after the program has curricula.',
          statusCode: 409,
        );
      }

      await tx.execute(
        Sql.named('''
          UPDATE academic_programs
          SET code = @code, name = @name, level = @level,
              department = @department, updated_at = NOW()
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {
          'id': id,
          'code': input.code,
          'name': input.name,
          'level': input.level,
          'department': input.department,
        },
      );
      return _programById(tx, id);
    });
  }

  /// Archives an academic program.
  static Future<void> deleteProgram(int id, int? actor) async {
    await _tx((tx) async {
      final program = await _programById(tx, id);

      if (_int(program['curriculum_count']) > 0) {
        throw AcademicException(
          "Delete this program's curricula first, then delete the program.",
          statusCode: 409,
        );
      }

      await _remove(tx, 'academic_programs', 'id = @id', {'id': id}, actor);
    });
  }

  // ------------------------------------------------------------------
  // subject catalog (shared across curricula)
  // ------------------------------------------------------------------

  static Map<String, dynamic> _catalogJson(ResultRow r) => {
    'id': _int(r[0]),
    'code': r[1],
    'name': r[2],
    'units': r[3],
    'hours': r[4],
  };

  /// Searches the subject catalog.
  static Future<List<Map<String, dynamic>>> searchCatalog(String? q) async {
    final term = _textOrNull(q);
    final result = await Database.pool.execute(
      Sql.named('''
        SELECT id, code, name, units::float8, hours
        FROM academic_subjects
        WHERE is_deleted = FALSE
          AND (@q::text IS NULL
               OR COALESCE(code, '') ILIKE '%' || @q::text || '%'
               OR name ILIKE '%' || @q::text || '%')
        ORDER BY code NULLS LAST, name
        LIMIT 30
      '''),
      parameters: {'q': term},
    );
    return result.map(_catalogJson).toList();
  }

  /// Finds a catalog subject by id, code or name, or creates it.
  static Future<int> _resolveSubject(
    Session s,
    Map<String, dynamic> body,
  ) async {
    final given = int.tryParse(body['subject_id']?.toString() ?? '');
    final code = _textOrNull(body['code'])?.toUpperCase();
    final name = _text(body['name']);

    final blob = '${code ?? ''} $name';
    if (_ojtLike.hasMatch(blob)) {
      throw AcademicException(
        'OJT, practicum, internship and work immersion subjects are not added.',
      );
    }

    if (given != null) {
      final found = await s.execute(
        Sql.named('''
          SELECT id, code, name FROM academic_subjects
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {'id': given},
      );
      if (found.isEmpty) {
        throw AcademicException('Subject not found.', statusCode: 404);
      }
      final foundBlob = '${found.first[1] ?? ''} ${found.first[2]}';
      if (_ojtLike.hasMatch(foundBlob)) {
        throw AcademicException(
          'OJT, practicum, internship and work immersion '
          'subjects are not added.',
        );
      }
      return given;
    }

    if (name.isEmpty) {
      throw AcademicException('Course name is required.');
    }
    if (name.length > 250) {
      throw AcademicException('Course name is too long.');
    }
    if (code != null && !_courseCode.hasMatch(code)) {
      throw AcademicException('Course code looks invalid (e.g. GEDC1002).');
    }

    final unitsRaw = body['units'];
    final units = unitsRaw == null || unitsRaw.toString().trim().isEmpty
        ? null
        : double.tryParse(unitsRaw.toString());
    if (unitsRaw != null &&
        unitsRaw.toString().trim().isNotEmpty &&
        (units == null || units < 0 || units > 99)) {
      throw AcademicException('Units must be a number.');
    }
    final hoursRaw = body['hours'];
    final hours = hoursRaw == null || hoursRaw.toString().trim().isEmpty
        ? null
        : int.tryParse(hoursRaw.toString());
    if (hoursRaw != null &&
        hoursRaw.toString().trim().isNotEmpty &&
        (hours == null || hours < 0)) {
      throw AcademicException('Hours must be a whole number.');
    }

    final existing = code != null
        ? await s.execute(
            Sql.named('''
              SELECT id, name FROM academic_subjects
              WHERE LOWER(code) = LOWER(@code) AND is_deleted = FALSE
            '''),
            parameters: {'code': code},
          )
        : await s.execute(
            Sql.named('''
              SELECT id, name FROM academic_subjects
              WHERE code IS NULL AND LOWER(name) = LOWER(@name)
                AND is_deleted = FALSE
            '''),
            parameters: {'name': name},
          );

    if (existing.isNotEmpty) {
      final existingName = existing.first[1]! as String;
      if (code != null && existingName.toLowerCase() != name.toLowerCase()) {
        throw AcademicException(
          'Course code $code already exists as "$existingName". '
          'Pick it from the list, or use a different code.',
          statusCode: 409,
        );
      }
      return _int(existing.first[0]);
    }

    final created = await s.execute(
      Sql.named('''
        INSERT INTO academic_subjects (code, name, units, hours)
        VALUES (@code, @name, @units, @hours)
        RETURNING id
      '''),
      parameters: {'code': code, 'name': name, 'units': units, 'hours': hours},
    );
    return _int(created.first[0]);
  }

  // ------------------------------------------------------------------
  // curricula
  // ------------------------------------------------------------------

  static Map<String, dynamic> _curriculumJson(ResultRow r) => {
    'id': _int(r[0]),
    'program_id': _int(r[1]),
    'code': r[2],
    'status': r[3],
    'copied_from_id': r[4] == null ? null : _int(r[4]),
    'published_at': r[5]?.toString(),
    'subject_count': _int(r[6]),
    'elective_count': _int(r[7]),
    'level': r[8],
  };

  static const _curriculumSelect = '''
    SELECT c.id, c.program_id, c.code, c.status, c.copied_from_id,
           c.published_at,
           (SELECT COUNT(*) FROM curriculum_subjects cs
             WHERE cs.curriculum_id = c.id AND cs.is_deleted = FALSE)::int,
           (SELECT COUNT(*) FROM curriculum_electives ce
             WHERE ce.curriculum_id = c.id AND ce.is_deleted = FALSE)::int,
           p.level
    FROM curricula c
    JOIN academic_programs p ON p.id = c.program_id
  ''';

  /// Lists curricula for a program.
  static Future<List<Map<String, dynamic>>> listCurricula({
    required int programId,
    String? status,
  }) async {
    final filter = _textOrNull(status);
    final result = await Database.pool.execute(
      Sql.named('''
        $_curriculumSelect
        WHERE c.program_id = @pid AND c.is_deleted = FALSE
          AND p.is_deleted = FALSE
          AND (@status::text IS NULL OR c.status = @status::text)
        ORDER BY c.code DESC
      '''),
      parameters: {'pid': programId, 'status': filter},
    );
    return result.map(_curriculumJson).toList();
  }

  static Future<Map<String, dynamic>> _curriculumById(
    Session s,
    int id,
  ) async {
    final result = await s.execute(
      Sql.named('''
        $_curriculumSelect
        WHERE c.id = @id AND c.is_deleted = FALSE AND p.is_deleted = FALSE
      '''),
      parameters: {'id': id},
    );
    if (result.isEmpty) {
      throw AcademicException('Curriculum not found.', statusCode: 404);
    }
    return _curriculumJson(result.first);
  }

  /// Gets a curriculum by ID.
  static Future<Map<String, dynamic>> getCurriculum(int id) async {
    return _curriculumById(Database.pool, id);
  }

  static String _curriculumCodeInput(Object? raw) {
    final code = _text(raw).toUpperCase();
    if (!_curriculumCode.hasMatch(code)) {
      throw AcademicException(
        'Curriculum code must be 2 to 20 letters, numbers or dashes '
        '(e.g. 2401).',
      );
    }
    return code;
  }

  static Future<String> _nextShsCode(
    Session s,
    int programId,
  ) async {
    final rows = await s.execute(
      Sql.named('''
      SELECT UPPER(code)
      FROM curricula
      WHERE program_id = @pid
        AND is_deleted = FALSE
    '''),
      parameters: {'pid': programId},
    );

    final used = rows.map((r) => r[0]?.toString()).whereType<String>().toSet();

    if (!used.contains('SHS')) {
      return 'SHS';
    }

    var n = 2;

    while (used.contains('SHS-$n')) {
      n++;
    }

    return 'SHS-$n';
  }

  static Future<Map<String, dynamic>> _requireDraft(
    Session s,
    int curriculumId,
  ) async {
    final c = await _curriculumById(s, curriculumId);
    if (c['status'] != 'draft') {
      throw AcademicException(
        'A published curriculum is read-only. Copy it to a draft '
        'to make changes.',
        statusCode: 409,
      );
    }
    return c;
  }

  /// Creates a draft curriculum. It can start empty, be copied from an
  /// existing curriculum of the same program, and/or be filled from rows read
  /// out of an uploaded file ({year_level, term, code, name, ...}).
  static Future<Map<String, dynamic>> createCurriculum(
    Map<String, dynamic> body,
    int? actor,
  ) async {
    final programId = int.tryParse(body['program_id']?.toString() ?? '');
    if (programId == null) {
      throw AcademicException('Choose a program.');
    }
    final copyFrom = int.tryParse(body['copy_from_id']?.toString() ?? '');
    final rows = body['rows'];
    if (rows != null && rows is! List) {
      throw AcademicException('rows must be a list.');
    }
    final electiveRows = body['electives'];
    if (electiveRows != null && electiveRows is! List) {
      throw AcademicException('electives must be a list.');
    }
    final hasFile =
        (rows is List && rows.isNotEmpty) ||
        (electiveRows is List && electiveRows.isNotEmpty);
    if (copyFrom != null && hasFile) {
      throw AcademicException(
        'Choose either Copy from an existing curriculum or an uploaded '
        'file, not both.',
      );
    }

    return _tx((tx) async {
      final program = await _programById(tx, programId);

      final code = program['level'] == 'shs'
          ? await _nextShsCode(tx, programId)
          : _curriculumCodeInput(body['code']);

      final dup = await tx.execute(
        Sql.named('''
          SELECT 1 FROM curricula
          WHERE program_id = @pid AND UPPER(code) = @code AND is_deleted = FALSE
        '''),
        parameters: {'pid': programId, 'code': code},
      );
      if (dup.isNotEmpty) {
        throw AcademicException(
          '${program['code']} already has a curriculum $code.',
          statusCode: 409,
        );
      }

      final created = await tx.execute(
        Sql.named('''
          INSERT INTO curricula (program_id, code, status, copied_from_id, created_by)
          VALUES (@pid, @code, 'draft', @from, @actor)
          RETURNING id
        '''),
        parameters: {
          'pid': programId,
          'code': code,
          'from': copyFrom,
          'actor': actor,
        },
      );
      final newId = _int(created.first[0]);

      if (copyFrom != null) {
        final source = await _curriculumById(tx, copyFrom);
        if (source['program_id'] != programId) {
          throw AcademicException(
            'You can only copy a curriculum of the same program.',
          );
        }
        await tx.execute(
          Sql.named('''
            INSERT INTO curriculum_subjects
              (curriculum_id, subject_id, year_level, term, category,
               is_elective_slot, hours, sort_order)
            SELECT @new, subject_id, year_level, term, category,
                   is_elective_slot, hours, sort_order
            FROM curriculum_subjects
            WHERE curriculum_id = @src AND is_deleted = FALSE
          '''),
          parameters: {'new': newId, 'src': copyFrom},
        );
        await tx.execute(
          Sql.named('''
            INSERT INTO curriculum_electives
              (curriculum_id, subject_id, group_name, sort_order)
            SELECT @new, subject_id, group_name, sort_order
            FROM curriculum_electives
            WHERE curriculum_id = @src AND is_deleted = FALSE
          '''),
          parameters: {'new': newId, 'src': copyFrom},
        );
      }

      if (rows is List && rows.isNotEmpty) {
        final maxYear = program['level'] == 'shs' ? 2 : 4;
        var order = 0;
        for (var i = 0; i < rows.length; i++) {
          final item = rows[i];
          if (item is! Map) {
            throw AcademicException('Row ${i + 1} of the file is invalid.');
          }
          final row = Map<String, dynamic>.from(item);
          try {
            final year = _year(row['year_level']);
            if (year > maxYear) {
              throw AcademicException(
                program['level'] == 'shs'
                    ? 'Senior High School only has Grade 11 and Grade 12.'
                    : 'Year level must be 1 to 4.',
              );
            }
            final term = _term(row['term']);
            final subjectId = await _resolveSubject(tx, row);
            order++;
            await tx.execute(
              Sql.named('''
                INSERT INTO curriculum_subjects
                  (curriculum_id, subject_id, year_level, term, category,
                   is_elective_slot, hours, sort_order)
                VALUES (@cid, @sid, @year, @term, @cat, @slot, @hours, @ord)
                ON CONFLICT DO NOTHING
              '''),
              parameters: {
                'cid': newId,
                'sid': subjectId,
                'year': year,
                'term': term,
                'cat': _category(row['category']),
                'slot': row['is_elective_slot'] == true,
                'hours': _hoursInput(row['hours']),
                'ord': order,
              },
            );
          } on AcademicException catch (e) {
            throw AcademicException(
              'File row ${i + 1}: ${e.message}',
              statusCode: e.statusCode,
            );
          }
        }
      }

      if (electiveRows is List && electiveRows.isNotEmpty) {
        var order = 0;
        for (var i = 0; i < electiveRows.length; i++) {
          final item = electiveRows[i];
          if (item is! Map) {
            throw AcademicException(
              'Elective ${i + 1} of the file is invalid.',
            );
          }
          final row = Map<String, dynamic>.from(item);
          try {
            final subjectId = await _resolveSubject(tx, row);
            order++;
            await tx.execute(
              Sql.named('''
                INSERT INTO curriculum_electives
                  (curriculum_id, subject_id, group_name, sort_order)
                VALUES (@cid, @sid, @grp, @ord)
                ON CONFLICT DO NOTHING
              '''),
              parameters: {
                'cid': newId,
                'sid': subjectId,
                'grp': _textOrNull(row['group_name']),
                'ord': order,
              },
            );
          } on AcademicException catch (e) {
            throw AcademicException(
              'Elective ${i + 1}: ${e.message}',
              statusCode: e.statusCode,
            );
          }
        }
      }

      if (hasFile) {
        final same = await _identicalTo(tx, newId, programId);
        if (same != null) {
          throw AcademicException(
            'This file is exactly the same as ${program['code']} $same. '
            'A new curriculum needs at least one change: a replaced, added or '
            'removed subject'
            '${program['level'] == 'shs' ? ', or a different group or required'
                      ' hours' : ' or elective'}. '
            'To start from the old one, use Copy existing and edit the draft.',
            statusCode: 409,
          );
        }
      }

      return _curriculumById(tx, newId);
    });
  }

  static String? _category(Object? raw) {
    final v = _textOrNull(raw)?.toLowerCase();
    if (v == null) return null;
    if (v != 'core' && v != 'applied' && v != 'specialized') {
      throw AcademicException(
        'Subject group must be core, applied or specialized.',
      );
    }
    return v;
  }

  /// Updates a draft curriculum.
  static Future<Map<String, dynamic>> updateCurriculum(
    int id,
    Map<String, dynamic> body,
  ) async {
    return _tx((tx) async {
      final current = await _requireDraft(tx, id);

      if (current['level'] == 'shs') {
        throw AcademicException(
          'Senior High School curriculum codes cannot be renamed.',
          statusCode: 409,
        );
      }

      final code = _curriculumCodeInput(body['code']);

      final dup = await tx.execute(
        Sql.named('''
          SELECT 1 FROM curricula
          WHERE program_id = @pid AND UPPER(code) = @code
            AND is_deleted = FALSE AND id <> @id
        '''),
        parameters: {'pid': current['program_id'], 'code': code, 'id': id},
      );
      if (dup.isNotEmpty) {
        throw AcademicException(
          'That program already has a curriculum $code.',
          statusCode: 409,
        );
      }

      await tx.execute(
        Sql.named('''
          UPDATE curricula SET code = @code, updated_at = NOW()
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {'id': id, 'code': code},
      );
      return _curriculumById(tx, id);
    });
  }

  /// Archives a draft curriculum.
  static Future<void> deleteCurriculum(int id, int? actor) async {
    await _tx((tx) async {
      await _requireDraft(tx, id);
      final p = {'id': id};

      // Archive children first so no child remains visible after deletion.
      await _remove(
        tx,
        'elective_selections',
        'curriculum_subject_id IN (SELECT id FROM curriculum_subjects '
            'WHERE curriculum_id = @id)',
        p,
        actor,
      );
      await _remove(
        tx,
        'curriculum_electives',
        'curriculum_id = @id',
        p,
        actor,
      );
      await _remove(tx, 'curriculum_subjects', 'curriculum_id = @id', p, actor);

      await _remove(tx, 'curricula', 'id = @id', p, actor);
    });
  }

  // ------------------------------------------------------------------
  // validation + publish
  // ------------------------------------------------------------------

  /// A canonical text of everything that makes a curriculum what it is:
  /// every subject per year level + semester (with group and hours for
  /// Senior High School) and the list of electives.
  static Future<String> _signature(Session s, int id) async {
    final subjects = await s.execute(
      Sql.named('''
        SELECT cs.year_level::int, cs.term::int,
               LOWER(COALESCE(a.code, a.name)),
               COALESCE(cs.category, ''),
               COALESCE(cs.hours, a.hours, -1)::int,
               cs.is_elective_slot
        FROM curriculum_subjects cs
        JOIN academic_subjects a ON a.id = cs.subject_id
        WHERE cs.curriculum_id = @id AND cs.is_deleted = FALSE
        ORDER BY 1, 2, 3, 4, 5, 6
      '''),
      parameters: {'id': id},
    );
    final electives = await s.execute(
      Sql.named('''
        SELECT LOWER(COALESCE(a.code, a.name))
        FROM curriculum_electives ce
        JOIN academic_subjects a ON a.id = ce.subject_id
        WHERE ce.curriculum_id = @id AND ce.is_deleted = FALSE
        ORDER BY 1
      '''),
      parameters: {'id': id},
    );

    final out = StringBuffer();
    for (final r in subjects) {
      out.write('S|${r[0]}|${r[1]}|${r[2]}|${r[3]}|${r[4]}|${r[5]};');
    }
    for (final r in electives) {
      out.write('E|${r[0]};');
    }
    return out.toString();
  }

  /// The code of another curriculum of the same program that has exactly
  /// the same content, or null when this one differs from all of them.
  static Future<String?> _identicalTo(
    Session s,
    int id,
    int programId,
  ) async {
    final mine = await _signature(s, id);
    final others = await s.execute(
      Sql.named('''
        SELECT id, code FROM curricula
        WHERE program_id = @pid AND id <> @id AND is_deleted = FALSE
        ORDER BY code
      '''),
      parameters: {'pid': programId, 'id': id},
    );
    for (final o in others) {
      if (await _signature(s, _int(o[0])) == mine) return o[1]! as String;
    }
    return null;
  }

  static Future<List<String>> _issues(Session s, int id) async {
    final issues = <String>[];
    final c = await _curriculumById(s, id);

    if (_int(c['subject_count']) == 0) {
      issues.add('The curriculum has no subjects.');
      return issues;
    }

    final shs = c['level'] == 'shs';
    final rows = await s.execute(
      Sql.named('''
        SELECT cs.year_level, cs.term, a.code, a.name, cs.category,
               COALESCE(cs.hours, a.hours)
        FROM curriculum_subjects cs
        JOIN academic_subjects a ON a.id = cs.subject_id
        WHERE cs.curriculum_id = @id AND cs.is_deleted = FALSE
        ORDER BY cs.year_level, cs.term, cs.sort_order
      '''),
      parameters: {'id': id},
    );

    final maxYear = shs ? 2 : 4;
    final seen = <String, String>{};
    for (final r in rows) {
      final year = _int(r[0]);
      final term = _int(r[1]);
      final code = r[2] as String?;
      final name = r[3]! as String;
      final where = '${_yearLabel(c['level'] as String, year)}, Sem $term';

      if (year > maxYear) {
        issues.add('$name is placed in an invalid year level ($where).');
      }
      if (_ojtLike.hasMatch('${code ?? ''} $name')) {
        issues.add(
          '$name is an OJT/practicum subject and must be removed ($where).',
        );
      }
      if (shs && r[4] == null) {
        issues.add(
          '$name needs a group: Core, Applied or Specialized ($where).',
        );
      }
      if (shs && r[5] == null) {
        issues.add('$name needs its required hours ($where).');
      }
      if (code != null) {
        final key = code.toLowerCase();
        if (seen.containsKey(key)) {
          issues.add(
            'Course code $code appears twice (${seen[key]} and $where).',
          );
        } else {
          seen[key] = where;
        }
      }
    }

    final same = await _identicalTo(s, id, c['program_id'] as int);
    if (same != null) {
      issues.add(
        'It is exactly the same as curriculum $same. Change at least one '
        'subject (replace, add or remove one'
        '${shs ? ', or change its group or required hours' : ' or an elective'}'
        ') before publishing.',
      );
    }
    return issues;
  }

  static String _yearLabel(String level, int year) {
    if (level == 'shs') return 'Grade ${10 + year}';
    const names = ['1st', '2nd', '3rd', '4th'];
    return '${names[year - 1]} Year';
  }

  /// Validates a curriculum before publishing.
  static Future<List<String>> validateCurriculum(int id) async {
    return _issues(Database.pool, id);
  }

  /// Publishes a draft curriculum. It must have at least one subject and
  /// pass all validation checks.
  static Future<Map<String, dynamic>> publishCurriculum(
    int id,
    int? actor,
  ) async {
    return _tx((tx) async {
      await _requireDraft(tx, id);
      final issues = await _issues(tx, id);
      if (issues.isNotEmpty) {
        throw AcademicException(
          'The curriculum cannot be published yet.',
          statusCode: 422,
          issues: issues,
        );
      }

      await tx.execute(
        Sql.named('''
          UPDATE curricula
          SET status = 'published', published_at = NOW(),
              published_by = @actor, updated_at = NOW()
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {'id': id, 'actor': actor},
      );
      return _curriculumById(tx, id);
    });
  }

  // ------------------------------------------------------------------
  // curriculum subjects (the term table)
  // ------------------------------------------------------------------

  static Map<String, dynamic> _csJson(ResultRow r) => {
    'id': _int(r[0]),
    'subject_id': _int(r[1]),
    'code': r[2],
    'name': r[3],
    'units': r[4],
    'hours': r[5],
    'year_level': _int(r[6]),
    'term': _int(r[7]),
    'category': r[8],
    'is_elective_slot': r[9] == true,
    'selection': r[10] == null
        ? null
        : {
            'elective_id': _int(r[10]),
            'code': r[11],
            'name': r[12],
            'school_year': r[13],
          },
  };

  /// Only the subjects of this exact curriculum + year level + semester.
  /// When [schoolYear] is given, each elective slot also reports the
  /// elective finalized for that school year (or null = keep as listed).
  static Future<List<Map<String, dynamic>>> listSubjects({
    required int curriculumId,
    required int yearLevel,
    required int term,
    String? q,
    String? schoolYear,
  }) async {
    await _curriculumById(Database.pool, curriculumId);
    final year = _year(yearLevel);
    final sem = _term(term);
    final sy = schoolYear == null || schoolYear.trim().isEmpty
        ? null
        : _validateSchoolYear(schoolYear);

    final result = await Database.pool.execute(
      Sql.named('''
        SELECT cs.id, cs.subject_id, a.code, a.name, a.units::float8, COALESCE(cs.hours, a.hours),
               cs.year_level::int, cs.term::int, cs.category,
               cs.is_elective_slot,
               ce.id, ea.code, ea.name, es.school_year
        FROM curriculum_subjects cs
        JOIN academic_subjects a ON a.id = cs.subject_id
        LEFT JOIN elective_selections es
               ON es.curriculum_subject_id = cs.id
              AND es.school_year = @sy::text
              AND es.is_deleted = FALSE
        LEFT JOIN curriculum_electives ce
               ON ce.id = es.elective_id AND ce.is_deleted = FALSE
        LEFT JOIN academic_subjects ea ON ea.id = ce.subject_id
        WHERE cs.curriculum_id = @cid
          AND cs.year_level = @year AND cs.term = @term
          AND cs.is_deleted = FALSE AND a.is_deleted = FALSE
          AND (@q::text IS NULL
               OR COALESCE(a.code, '') ILIKE '%' || @q::text || '%'
               OR a.name ILIKE '%' || @q::text || '%')
        ORDER BY cs.sort_order, cs.id
      '''),
      parameters: {
        'cid': curriculumId,
        'year': year,
        'term': sem,
        'q': _textOrNull(q),
        'sy': sy,
      },
    );
    return result.map(_csJson).toList();
  }

  static Future<Map<String, dynamic>> _csById(Session s, int id) async {
    final result = await s.execute(
      Sql.named('''
        SELECT cs.id, cs.subject_id, a.code, a.name, a.units::float8, COALESCE(cs.hours, a.hours),
               cs.year_level::int, cs.term::int, cs.category,
               cs.is_elective_slot,
               NULL::bigint, NULL::text, NULL::text, NULL::text
        FROM curriculum_subjects cs
        JOIN academic_subjects a ON a.id = cs.subject_id
        WHERE cs.id = @id AND cs.is_deleted = FALSE
      '''),
      parameters: {'id': id},
    );
    if (result.isEmpty) {
      throw AcademicException('Subject not found.', statusCode: 404);
    }
    return _csJson(result.first);
  }

  static Future<void> _requireMember(
    Session s,
    int curriculumId,
    int csId,
  ) async {
    final r = await s.execute(
      Sql.named('''
        SELECT 1 FROM curriculum_subjects
        WHERE id = @id AND curriculum_id = @cid AND is_deleted = FALSE
      '''),
      parameters: {'id': csId, 'cid': curriculumId},
    );
    if (r.isEmpty) {
      throw AcademicException('Subject not found.', statusCode: 404);
    }
  }

  static void _checkYearForLevel(Map<String, dynamic> curriculum, int year) {
    if (curriculum['level'] == 'shs' && year > 2) {
      throw AcademicException(
        'Senior High School only has Grade 11 and Grade 12.',
      );
    }
  }

  /// Adds a curriculum subject.
  static Future<Map<String, dynamic>> addSubject(
    int curriculumId,
    Map<String, dynamic> body,
  ) async {
    final year = _year(body['year_level']);
    final term = _term(body['term']);
    final category = _category(body['category']);
    final slot = body['is_elective_slot'] == true;
    final hours = _hoursInput(body['hours']);

    return _tx((tx) async {
      final c = await _requireDraft(tx, curriculumId);
      _checkYearForLevel(c, year);
      final subjectId = await _resolveSubject(tx, body);

      final dup = await tx.execute(
        Sql.named('''
          SELECT 1 FROM curriculum_subjects
          WHERE curriculum_id = @cid AND year_level = @year AND term = @term
            AND subject_id = @sid AND is_deleted = FALSE
        '''),
        parameters: {
          'cid': curriculumId,
          'year': year,
          'term': term,
          'sid': subjectId,
        },
      );
      if (dup.isNotEmpty) {
        throw AcademicException(
          'That subject is already in this term.',
          statusCode: 409,
        );
      }

      final created = await tx.execute(
        Sql.named('''
          INSERT INTO curriculum_subjects
            (curriculum_id, subject_id, year_level, term, category,
             is_elective_slot, hours, sort_order)
          VALUES (@cid, @sid, @year, @term, @cat, @slot, @hours,
            COALESCE((SELECT MAX(sort_order) FROM curriculum_subjects
                      WHERE curriculum_id = @cid), 0) + 1)
          RETURNING id
        '''),
        parameters: {
          'cid': curriculumId,
          'sid': subjectId,
          'year': year,
          'term': term,
          'cat': category,
          'slot': slot,
          'hours': hours,
        },
      );
      return _csById(tx, _int(created.first[0]));
    });
  }

  /// Updates a curriculum subject.
  static Future<Map<String, dynamic>> updateSubject(
    int curriculumId,
    int csId,
    Map<String, dynamic> body, {
    int? actor,
  }) async {
    return _tx((tx) async {
      final c = await _requireDraft(tx, curriculumId);
      await _requireMember(tx, curriculumId, csId);
      final current = await _csById(tx, csId);

      final year = body.containsKey('year_level')
          ? _year(body['year_level'])
          : current['year_level'] as int;
      final term = body.containsKey('term')
          ? _term(body['term'])
          : current['term'] as int;
      _checkYearForLevel(c, year);

      final category = body.containsKey('category')
          ? _category(body['category'])
          : current['category'] as String?;
      final slot = body.containsKey('is_elective_slot')
          ? body['is_elective_slot'] == true
          : current['is_elective_slot'] as bool;

      final hours = body.containsKey('hours')
          ? _hoursInput(body['hours'])
          : current['hours'] as int?;

      var subjectId = current['subject_id'] as int;
      if (body.containsKey('subject_id') ||
          body.containsKey('code') ||
          body.containsKey('name')) {
        subjectId = await _resolveSubject(tx, body);
      }

      final dup = await tx.execute(
        Sql.named('''
          SELECT 1 FROM curriculum_subjects
          WHERE curriculum_id = @cid AND year_level = @year AND term = @term
            AND subject_id = @sid AND is_deleted = FALSE AND id <> @id
        '''),
        parameters: {
          'cid': curriculumId,
          'year': year,
          'term': term,
          'sid': subjectId,
          'id': csId,
        },
      );
      if (dup.isNotEmpty) {
        throw AcademicException(
          'That subject is already in this term.',
          statusCode: 409,
        );
      }

      // A different subject or a slot turned off invalidates old selections.
      if (subjectId != current['subject_id'] || !slot) {
        await _remove(
          tx,
          'elective_selections',
          'curriculum_subject_id = @id',
          {'id': csId},
          actor,
        );
      }

      await tx.execute(
        Sql.named('''
          UPDATE curriculum_subjects
          SET subject_id = @sid, year_level = @year, term = @term,
              category = @cat, is_elective_slot = @slot, hours = @hours,
              updated_at = NOW()
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {
          'id': csId,
          'sid': subjectId,
          'year': year,
          'term': term,
          'cat': category,
          'slot': slot,
          'hours': hours,
        },
      );
      return _csById(tx, csId);
    });
  }

  /// Archives a curriculum subject.
  static Future<void> deleteSubject(
    int curriculumId,
    int csId,
    int? actor,
  ) async {
    await _tx((tx) async {
      await _requireDraft(tx, curriculumId);
      await _requireMember(tx, curriculumId, csId);

      await _remove(
        tx,
        'elective_selections',
        'curriculum_subject_id = @id',
        {'id': csId},
        actor,
      );
      await _remove(
        tx,
        'curriculum_subjects',
        'id = @id AND curriculum_id = @cid',
        {'id': csId, 'cid': curriculumId},
        actor,
      );
    });
  }

  /// Deletes every subject of one year level + semester. Returns the count.
  static Future<int> deleteTermSubjects({
    required int curriculumId,
    required int yearLevel,
    required int term,
    int? actor,
  }) async {
    final year = _year(yearLevel);
    final sem = _term(term);

    return _tx((tx) async {
      await _requireDraft(tx, curriculumId);

      final count = await tx.execute(
        Sql.named('''
          SELECT COUNT(*)::int FROM curriculum_subjects
          WHERE curriculum_id = @cid AND year_level = @year AND term = @term
            AND is_deleted = FALSE
        '''),
        parameters: {'cid': curriculumId, 'year': year, 'term': sem},
      );
      final n = _int(count.first[0]);
      if (n == 0) return 0;

      final p = {'cid': curriculumId, 'year': year, 'term': sem};
      await _remove(
        tx,
        'elective_selections',
        '''
curriculum_subject_id IN (
             SELECT id FROM curriculum_subjects
             WHERE curriculum_id = @cid AND year_level = @year AND term = @term)''',
        p,
        actor,
      );
      await _remove(
        tx,
        'curriculum_subjects',
        'curriculum_id = @cid AND year_level = @year AND term = @term',
        p,
        actor,
      );
      return n;
    });
  }

  // ------------------------------------------------------------------
  // list of electives
  // ------------------------------------------------------------------

  static Map<String, dynamic> _electiveJson(ResultRow r) => {
    'id': _int(r[0]),
    'subject_id': _int(r[1]),
    'code': r[2],
    'name': r[3],
    'units': r[4],
    'group_name': r[5],
  };

  static const _electiveSelect = '''
    SELECT ce.id, ce.subject_id, a.code, a.name, a.units::float8, ce.group_name
    FROM curriculum_electives ce
    JOIN academic_subjects a ON a.id = ce.subject_id
  ''';

  /// Lists electives for a curriculum.
  static Future<List<Map<String, dynamic>>> listElectives(
    int curriculumId,
  ) async {
    await _curriculumById(Database.pool, curriculumId);
    final result = await Database.pool.execute(
      Sql.named('''
        $_electiveSelect
        WHERE ce.curriculum_id = @cid AND ce.is_deleted = FALSE
          AND a.is_deleted = FALSE
        ORDER BY ce.group_name NULLS LAST, ce.sort_order, ce.id
      '''),
      parameters: {'cid': curriculumId},
    );
    return result.map(_electiveJson).toList();
  }

  static Future<Map<String, dynamic>> _electiveById(Session s, int id) async {
    final result = await s.execute(
      Sql.named('$_electiveSelect WHERE ce.id = @id AND ce.is_deleted = FALSE'),
      parameters: {'id': id},
    );
    if (result.isEmpty) {
      throw AcademicException('Elective not found.', statusCode: 404);
    }
    return _electiveJson(result.first);
  }

  static Future<void> _requireElectiveMember(
    Session s,
    int curriculumId,
    int electiveId,
  ) async {
    final r = await s.execute(
      Sql.named('''
        SELECT 1 FROM curriculum_electives
        WHERE id = @id AND curriculum_id = @cid AND is_deleted = FALSE
      '''),
      parameters: {'id': electiveId, 'cid': curriculumId},
    );
    if (r.isEmpty) {
      throw AcademicException('Elective not found.', statusCode: 404);
    }
  }

  /// Adds a curriculum elective.
  static Future<Map<String, dynamic>> addElective(
    int curriculumId,
    Map<String, dynamic> body,
  ) async {
    final group = _textOrNull(body['group_name']);
    if (group != null && group.length > 120) {
      throw AcademicException('Group name is too long.');
    }

    return _tx((tx) async {
      await _requireDraft(tx, curriculumId);
      final subjectId = await _resolveSubject(tx, body);

      final dup = await tx.execute(
        Sql.named('''
          SELECT 1 FROM curriculum_electives
          WHERE curriculum_id = @cid AND subject_id = @sid AND is_deleted = FALSE
        '''),
        parameters: {'cid': curriculumId, 'sid': subjectId},
      );
      if (dup.isNotEmpty) {
        throw AcademicException(
          'That elective is already in the list.',
          statusCode: 409,
        );
      }

      final created = await tx.execute(
        Sql.named('''
          INSERT INTO curriculum_electives
            (curriculum_id, subject_id, group_name, sort_order)
          VALUES (@cid, @sid, @grp,
            COALESCE((SELECT MAX(sort_order) FROM curriculum_electives
                      WHERE curriculum_id = @cid), 0) + 1)
          RETURNING id
        '''),
        parameters: {'cid': curriculumId, 'sid': subjectId, 'grp': group},
      );
      return _electiveById(tx, _int(created.first[0]));
    });
  }

  /// Updates a curriculum elective.
  static Future<Map<String, dynamic>> updateElective(
    int curriculumId,
    int electiveId,
    Map<String, dynamic> body,
  ) async {
    return _tx((tx) async {
      await _requireDraft(tx, curriculumId);
      await _requireElectiveMember(tx, curriculumId, electiveId);
      final current = await _electiveById(tx, electiveId);

      final group = body.containsKey('group_name')
          ? _textOrNull(body['group_name'])
          : current['group_name'] as String?;

      var subjectId = current['subject_id'] as int;
      if (body.containsKey('subject_id') ||
          body.containsKey('code') ||
          body.containsKey('name')) {
        subjectId = await _resolveSubject(tx, body);
      }

      if (subjectId != current['subject_id']) {
        final used = await tx.execute(
          Sql.named('''
            SELECT 1 FROM elective_selections
            WHERE elective_id = @id AND is_deleted = FALSE LIMIT 1
          '''),
          parameters: {'id': electiveId},
        );
        if (used.isNotEmpty) {
          throw AcademicException(
            'This elective is finalized for a school year. '
            'Clear that choice first.',
            statusCode: 409,
          );
        }
        final dup = await tx.execute(
          Sql.named('''
            SELECT 1 FROM curriculum_electives
            WHERE curriculum_id = @cid AND subject_id = @sid
              AND is_deleted = FALSE AND id <> @id
          '''),
          parameters: {'cid': curriculumId, 'sid': subjectId, 'id': electiveId},
        );
        if (dup.isNotEmpty) {
          throw AcademicException(
            'That elective is already in the list.',
            statusCode: 409,
          );
        }
      }

      await tx.execute(
        Sql.named('''
          UPDATE curriculum_electives
          SET subject_id = @sid, group_name = @grp, updated_at = NOW()
          WHERE id = @id AND is_deleted = FALSE
        '''),
        parameters: {'id': electiveId, 'sid': subjectId, 'grp': group},
      );
      return _electiveById(tx, electiveId);
    });
  }

  /// Archives a curriculum elective.
  static Future<void> deleteElective(
    int curriculumId,
    int electiveId,
    int? actor,
  ) async {
    await _tx((tx) async {
      await _requireDraft(tx, curriculumId);
      await _requireElectiveMember(tx, curriculumId, electiveId);

      final used = await tx.execute(
        Sql.named('''
          SELECT school_year FROM elective_selections
          WHERE elective_id = @id AND is_deleted = FALSE
          ORDER BY school_year
        '''),
        parameters: {'id': electiveId},
      );
      if (used.isNotEmpty) {
        final years = used.map((r) => r[0]).join(', ');
        throw AcademicException(
          'This elective is finalized for $years. Clear that choice first.',
          statusCode: 409,
        );
      }

      await _remove(
        tx,
        'curriculum_electives',
        'id = @id AND curriculum_id = @cid',
        {'id': electiveId, 'cid': curriculumId},
        actor,
      );
    });
  }

  // ------------------------------------------------------------------
  // elective selections (finalized per school year)
  // ------------------------------------------------------------------
  /// Lists finalized elective selections.
  static Future<List<Map<String, dynamic>>> listSelections({
    required int curriculumId,
    required String schoolYear,
  }) async {
    await _curriculumById(Database.pool, curriculumId);
    final sy = _validateSchoolYear(schoolYear);

    final result = await Database.pool.execute(
      Sql.named('''
        SELECT es.curriculum_subject_id, ce.id, a.code, a.name, es.school_year
        FROM elective_selections es
        JOIN curriculum_subjects cs ON cs.id = es.curriculum_subject_id
        JOIN curriculum_electives ce ON ce.id = es.elective_id
        JOIN academic_subjects a ON a.id = ce.subject_id
        WHERE cs.curriculum_id = @cid AND es.school_year = @sy
          AND es.is_deleted = FALSE AND cs.is_deleted = FALSE
          AND ce.is_deleted = FALSE
        ORDER BY cs.id
      '''),
      parameters: {'cid': curriculumId, 'sy': sy},
    );
    return result
        .map(
          (r) => {
            'curriculum_subject_id': _int(r[0]),
            'elective_id': _int(r[1]),
            'code': r[2],
            'name': r[3],
            'school_year': r[4],
          },
        )
        .toList();
  }

  /// Finalizes an elective for a slot in a school year (works on published
  /// curricula, because it does not change the curriculum itself).
  static Future<Map<String, dynamic>> setSelection(
    int curriculumId,
    Map<String, dynamic> body,
    int? actor,
  ) async {
    final csId = int.tryParse(body['curriculum_subject_id']?.toString() ?? '');
    final electiveId = int.tryParse(body['elective_id']?.toString() ?? '');
    if (csId == null || electiveId == null) {
      throw AcademicException('Choose the subject slot and the elective.');
    }
    final sy = _validateSchoolYear(body['school_year']);

    return _tx((tx) async {
      await _curriculumById(tx, curriculumId);
      await _requireMember(tx, curriculumId, csId);
      await _requireElectiveMember(tx, curriculumId, electiveId);

      final slot = await tx.execute(
        Sql.named(
          'SELECT is_elective_slot FROM curriculum_subjects WHERE id = @id',
        ),
        parameters: {'id': csId},
      );
      if (slot.first[0] != true) {
        throw AcademicException('This subject is not an elective slot.');
      }

      await _remove(
        tx,
        'elective_selections',
        'curriculum_subject_id = @cs AND school_year = @sy',
        {'cs': csId, 'sy': sy},
        actor,
      );
      await tx.execute(
        Sql.named('''
          INSERT INTO elective_selections
            (curriculum_subject_id, elective_id, school_year, created_by)
          VALUES (@cs, @el, @sy, @actor)
        '''),
        parameters: {'cs': csId, 'el': electiveId, 'sy': sy, 'actor': actor},
      );

      final el = await _electiveById(tx, electiveId);
      return {
        'curriculum_subject_id': csId,
        'elective_id': electiveId,
        'code': el['code'],
        'name': el['name'],
        'school_year': sy,
      };
    });
  }

  /// Archives an elective selection.
  static Future<void> clearSelection({
    required int curriculumId,
    required int curriculumSubjectId,
    required String schoolYear,
    int? actor,
  }) async {
    final sy = _validateSchoolYear(schoolYear);
    await _tx((tx) async {
      await _curriculumById(tx, curriculumId);
      await _requireMember(tx, curriculumId, curriculumSubjectId);
      await _remove(
        tx,
        'elective_selections',
        'curriculum_subject_id = @cs AND school_year = @sy',
        {'cs': curriculumSubjectId, 'sy': sy},
        actor,
      );
    });
  }
}
