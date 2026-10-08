import 'package:server/teachers/teacher_exception.dart';

/// Deterministic rules for a teacher's name, Teacher ID No., department and
/// institutional email. The Flutter screen has a mirror of these rules for
/// instant feedback; THIS file is the authority.
class TeacherIdentity {
  TeacherIdentity._({
    required this.teacherIdNo,
    required this.firstName,
    required this.middleName,
    required this.lastName,
    required this.fullName,
    required this.email,
    required this.department,
  });

  final String teacherIdNo;
  final String firstName;
  final String middleName;
  final String lastName;
  final String fullName;
  final String email;
  final String department;

  static const emailDomain = 'sti.checkmate.com';

  static const departments = <String>[
    'IT Department',
    'Business Administration Department',
    'Hospitality and Tourism Management Department',
    'Engineering Department',
    'General Education Department',
  ];

  static const _letter = 'A-Za-zÀ-ÖØ-öø-ÿĀ-ſ';
  static final _nameChars = RegExp("^[$_letter][$_letter .'’-]*\$");
  static final _lettersOnly = RegExp('[^$_letter]');
  static final _teacherId = RegExp(r'^\d{3,20}$');
  static const _fold = <String, String>{
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'ă': 'a', 'ą': 'a', 'æ': 'ae', 'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd',
    'đ': 'd', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e',
    'ě': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ł': 'l',
    'ñ': 'n', 'ń': 'n', 'ň': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
    'ö': 'o', 'ø': 'o', 'ō': 'o', 'œ': 'oe', 'ř': 'r', 'ś': 's', 'š': 's',
    'ş': 's', 'ß': 'ss', 'ť': 't', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ū': 'u', 'ů': 'u', 'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
  };

  static String collapse(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String titleCase(String input) {
    final out = StringBuffer();
    var startOfWord = true;

    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);

      if (' -\'’.'.contains(ch)) {
        out.write(ch);
        startOfWord = true;
      } else {
        out.write(startOfWord ? ch.toUpperCase() : ch.toLowerCase());
        startOfWord = false;
      }
    }

    return out.toString();
  }

  static String normalizeName(String raw) => titleCase(collapse(raw));

  static String? nameError(
    String raw, {
    required String label,
    required bool isRequired,
    int minLetters = 2,
  }) {
    final v = collapse(raw);

    if (v.isEmpty) return isRequired ? '$label is required.' : null;

    if (v.length > 50) return '$label must be 50 characters or fewer.';

    if (RegExp(r'[0-9]').hasMatch(v)) {
      return '$label cannot contain numbers.';
    }

    if (!_nameChars.hasMatch(v)) {
      return '$label can only contain letters, spaces, hyphens (-), '
          "apostrophes (') and periods (.).";
    }

    if (RegExp("[.'’-]{2,}|(^|\\s)[-'’]|[-'’](\\s|\$)").hasMatch(v)) {
      return '$label has misplaced punctuation.';
    }

    if (v.replaceAll(_lettersOnly, '').length < minLetters) {
      return minLetters > 1
          ? '$label is too short.'
          : '$label must contain a letter.';
    }

    return null;
  }

  static String? teacherIdError(String raw) {
    final v = raw.trim();

    if (v.isEmpty) return 'Teacher ID No. is required.';

    if (!_teacherId.hasMatch(v)) {
      return 'Teacher ID No. must contain 3–20 digits only.';
    }

    return null;
  }

  static String slug(String input) {
    final out = StringBuffer();

    for (final rune in input.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      final code = rune;

      final isLower = code >= 0x61 && code <= 0x7A;
      final isDigit = code >= 0x30 && code <= 0x39;

      if (isLower || isDigit) {
        out.write(ch);
      } else {
        final folded = _fold[ch];
        if (folded != null) out.write(folded);
      }
    }

    return out.toString();
  }

static String? buildEmail({
  required String firstName,
  required String middleName,
  required String lastName,
  required String teacherIdNo,
}) {
  final surname = slug(lastName);
  final first = slug(firstName);
  final id = teacherIdNo.trim().toLowerCase();

  if (surname.isEmpty || first.isEmpty || id.isEmpty) return null;

  final local = [
    surname,
    first[0],
    id,
  ].join('.');

  return '$local@$emailDomain';
}

  static String? matchDepartment(String raw) {
    final v = collapse(raw).toLowerCase();

    for (final d in departments) {
      if (d.toLowerCase() == v) return d;
    }

    return null;
  }

  static TeacherIdentity validate({
    required String teacherIdNo,
    required String firstName,
    required String middleName,
    required String lastName,
    required String department,
  }) {
    final idError = teacherIdError(teacherIdNo);
    if (idError != null) throw TeacherException(idError);

    final firstError =
        nameError(firstName, label: 'First name', isRequired: true);
    if (firstError != null) throw TeacherException(firstError);

    final middleError = nameError(
      middleName,
      label: 'Middle name',
      isRequired: false,
      minLetters: 1,
    );
    if (middleError != null) throw TeacherException(middleError);

    final lastError =
        nameError(lastName, label: 'Last name', isRequired: true);
    if (lastError != null) throw TeacherException(lastError);

    final dept = matchDepartment(department);
    if (dept == null) {
      throw TeacherException('Please choose a department from the list.');
    }

    final first = normalizeName(firstName);
    final middle = normalizeName(middleName);
    final last = normalizeName(lastName);
    final id = teacherIdNo.trim();

    final email = buildEmail(
      firstName: first,
      middleName: middle,
      lastName: last,
      teacherIdNo: id,
    );

    if (email == null) {
      throw TeacherException(
        'First and last names must contain at least one letter A-Z so an '
        'email address can be generated.',
      );
    }

    if (email.split('@').first.length > 64) {
      throw TeacherException(
        'The name and Teacher ID make an email address that is too long.',
      );
    }

    return TeacherIdentity._(
      teacherIdNo: id,
      firstName: first,
      middleName: middle,
      lastName: last,
      fullName: [first, middle, last].where((p) => p.isNotEmpty).join(' '),
      email: email,
      department: dept,
    );
  }
}
