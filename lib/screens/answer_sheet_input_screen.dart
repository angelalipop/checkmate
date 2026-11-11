import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/my_subjects_api_service.dart';
import 'answer_sheet_camera_screen.dart';
import 'answer_sheet_upload_screen.dart';
import 'teacher_dashboard.dart' show TeacherPage, TeacherShell;

// =============================================================
// CheckMate Brand Palette & Tokens (Scanner Entry)
// =============================================================
const Color _kNavy = Color(0xFF1E293B);
const Color _kNavyDark = Color(0xFF162137);
const Color _kSlate = Color(0xFF64748B);
const Color _kBg = Color(0xFFF8FAFC);
const Color _kLine = Color(0xFFE2E8F0);
const Color _kEmerald = Color(0xFF10B981);
const Color _kEmeraldDark = Color(0xFF047857);
const Color _kAmber = Color(0xFFF59E0B);

class AnswerSheetInputScreen extends StatefulWidget {
  const AnswerSheetInputScreen({
    super.key,
    this.initialExamId,
  });

  final int? initialExamId;

  @override
  State<AnswerSheetInputScreen> createState() =>
      _AnswerSheetInputScreenState();
}

class _AnswerSheetInputScreenState extends State<AnswerSheetInputScreen> {
  bool _isLoading = true;
  bool _isLoadingAssessments = false;
  bool _isLoadingSections = false;
  bool _isDownloadingSheet = false;

  // Cascading filter state: Subject -> Section -> Active/Published Assessment
  List<Map<String, dynamic>> _subjects = [];
  Map<String, dynamic>? _selectedSubject;
  Map<String, dynamic>? _selectedSection; // {'class_id': int, 'name': String, 'students': int}

  List<Map<String, dynamic>> _allExams = [];
  List<Map<String, dynamic>> _exams = [];
  Map<String, dynamic>? _selectedExam;
  List<Map<String, dynamic>> _selectedExamSections = [];
  List<Map<String, dynamic>> _selectedExamStudents = [];

  @override
  void initState() {
    super.initState();
    _loadExams();
  }

  // =========================
  // LOAD SUBJECTS, SECTIONS & EXAMS
  // =========================

  Future<void> _loadExams() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session expired. Please log in again.'),
          ),
        );
        return;
      }

      List<Map<String, dynamic>> subjects = [];
      try {
        subjects = await MySubjectsApi.subjects(token);
      } catch (_) {
        subjects = [];
      }

      List<Map<String, dynamic>> allExams = [];
      try {
        allExams = await ApiService.getExams(token);
      } catch (_) {
        allExams = [];
      }

      // Fallback: derive subject & section entries from exams if MySubjectsApi
      // returned empty.
      if (subjects.isEmpty && allExams.isNotEmpty) {
        final bySubj = <String, Map<String, dynamic>>{};
        for (final e in allExams) {
          final cls = e['class'];
          final subj = cls is Map ? cls['subject'] : e['subject'];
          final code = (subj is Map ? subj['code'] : e['subject_code'])
                  ?.toString()
                  .trim() ??
              '';
          final name = (subj is Map ? subj['name'] : e['subject_name'])
                  ?.toString()
                  .trim() ??
              '';
          final classId = int.tryParse(
            '${e['class_id'] ?? (cls is Map ? cls['id'] : '')}',
          );
          final secName =
              (cls is Map ? cls['section'] : e['section'])?.toString().trim() ??
                  '';
          if (code.isEmpty && name.isEmpty) continue;
          final key = '$code|$name';
          final card = bySubj.putIfAbsent(
            key,
            () => <String, dynamic>{
              'key': key,
              'code': code,
              'name': name,
              'sections': <Map<String, dynamic>>[],
            },
          );
          if (classId != null && secName.isNotEmpty) {
            final secList = card['sections'] as List<Map<String, dynamic>>;
            if (!secList.any((s) => s['class_id'] == classId)) {
              secList.add({
                'class_id': classId,
                'name': secName,
                'students': 0,
              });
            }
          }
        }
        subjects = bySubj.values.toList();
      }

      if (!mounted) return;

      setState(() {
        _subjects = subjects;
        _allExams = allExams;
        _selectedSubject = null;
        _selectedSection = null;
        _exams = [];
        _selectedExam = null;
        _selectedExamSections = [];
        _selectedExamStudents = [];
        _isLoading = false;
      });

      // If an initialExamId was supplied, pre-select its Subject, Section, and Assessment.
      if (widget.initialExamId != null) {
        await _preselectInitialExam(widget.initialExamId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load subjects and exams: $e'),
        ),
      );
    }
  }

  Future<void> _preselectInitialExam(int targetExamId) async {
    Map<String, dynamic>? targetExam;
    for (final e in _allExams) {
      if (int.tryParse('${e['id']}') == targetExamId) {
        targetExam = Map<String, dynamic>.from(e);
        break;
      }
    }
    try {
      final token = await AuthStorage.getToken();
      if (token != null && token.isNotEmpty) {
        final fullExam = await ApiService.getExamById(token, targetExamId);
        targetExam = <String, dynamic>{
          if (targetExam != null) ...targetExam,
          ...fullExam,
        };
        final idx = _allExams.indexWhere(
          (e) => int.tryParse('${e['id']}') == targetExamId,
        );
        if (idx >= 0) {
          _allExams[idx] = targetExam;
        } else {
          _allExams.add(targetExam);
        }
      }
    } catch (_) {}
    if (targetExam == null || targetExam['creation_mode']=='manual') return;

    for (final subj in _subjects) {
      final sections = _subjectSections(subj);
      for (final sec in sections) {
        final cid = int.tryParse('${sec['class_id']}');
        final secName = (sec['name']?.toString() ?? '').trim();
        if (cid != null && _examBelongsToClass(targetExam, cid, secName)) {
          setState(() {
            _selectedSubject = subj;
            _selectedSection = sec;
          });
          await _loadAssessmentsForSection(
            sec,
            preferredExamId: targetExamId,
          );
          return;
        }
      }
    }

    final targetSubjId = int.tryParse(
      '${targetExam['subject_id'] ?? (targetExam['class'] is Map ? (targetExam['class'] as Map)['subject_id'] : '')}',
    );
    final targetSubjCode =
        (targetExam['subject_code']?.toString() ?? '').trim().toLowerCase();
    for (final subj in _subjects) {
      final sid = int.tryParse('${subj['subject_id']}');
      final scode = (subj['code']?.toString() ?? '').trim().toLowerCase();
      final matchesSubject = (targetSubjId != null && sid == targetSubjId) ||
          (targetSubjCode.isNotEmpty && scode == targetSubjCode);
      if (matchesSubject) {
        final sections = _subjectSections(subj);
        if (sections.isNotEmpty) {
          final sec = sections.first;
          setState(() {
            _selectedSubject = subj;
            _selectedSection = sec;
          });
          await _loadAssessmentsForSection(
            sec,
            preferredExamId: targetExamId,
          );
          return;
        }
      }
    }
  }

  List<Map<String, dynamic>> _subjectSections(Map<String, dynamic>? subject) {
    if (subject == null) return [];
    final raw = subject['sections'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
  }

  bool _isActiveAndPublished(Map<String, dynamic> exam) {
    if(exam['creation_mode']=='manual')return false;
    final status = (exam['status']?.toString() ?? '').trim().toLowerCase();
    return status == 'published' || status == 'active';
  }

  bool _examBelongsToClass(Map<String, dynamic> exam, int classId, String sectionName) {
    final directCid = int.tryParse('${exam['class_id'] ?? ''}');
    if (directCid == classId) return true;

    final cls = exam['class'];
    if (cls is Map) {
      final nestedCid = int.tryParse('${cls['id'] ?? ''}');
      if (nestedCid == classId) return true;
    }

    if (exam['class_ids'] is List) {
      for (final item in exam['class_ids'] as List) {
        if (int.tryParse('$item') == classId) return true;
      }
    }

    if (sectionName.isNotEmpty && exam['sections'] is List) {
      for (final s in exam['sections'] as List) {
        if (s is String && s.trim().toLowerCase() == sectionName.toLowerCase()) {
          return true;
        }
      }
    }

    return false;
  }

  Future<void> _loadAssessmentsForSection(
    Map<String, dynamic> section, {
    int? preferredExamId,
  }) async {
    final int? classId = int.tryParse('${section['class_id']}');
    final String sectionName = (section['name']?.toString() ?? '').trim();
    if (classId == null) return;

    setState(() {
      _isLoadingAssessments = true;
      _exams = [];
      _selectedExam = null;
      _selectedExamSections = [];
      _selectedExamStudents = [];
    });

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Session expired. Please log in again.');
      }

      // 1. Fetch section-scoped assessments from /my-subjects/assessments.
      List<Map<String, dynamic>> sectionAssessments = [];
      try {
        sectionAssessments = await MySubjectsApi.assessments(token, [classId]);
      } catch (_) {
        sectionAssessments = [];
      }

      // 2. Also load enrolled students and scorebook completion status for this
      // exact section so the student count, roster, and "needed scanning" filter
      // are immediately accurate.
      List<Map<String, dynamic>> sectionStudents = [];
      try {
        sectionStudents = await ApiService.getStudents(token, classId: classId);
      } catch (_) {
        sectionStudents = [];
      }

      final Set<int> fullyCompletedExamIds = <int>{};
      try {
        final sb = await MySubjectsApi.scorebook(token, classId);
        final sbStudents = (sb['students'] is List)
            ? (sb['students'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : <Map<String, dynamic>>[];
        final sbAssessments = (sb['assessments'] is List)
            ? (sb['assessments'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : <Map<String, dynamic>>[];

        if (sbStudents.isNotEmpty) {
          for (final a in sbAssessments) {
            final aid = int.tryParse('${a['id']}');
            if (aid == null) continue;
            int pendingCount = 0;
            for (final st in sbStudents) {
              final scores = st['scores'];
              final cell = (scores is Map) ? scores['$aid'] : null;
              final stStatus = (cell is Map ? cell['status'] : null)
                      ?.toString()
                      .toLowerCase() ??
                  'pending';
              if (stStatus == 'pending') {
                pendingCount++;
              }
            }
            if (pendingCount == 0 && aid != preferredExamId) {
              fullyCompletedExamIds.add(aid);
            }
          }
        }
      } catch (_) {
        // Ignore scorebook check errors; rely on active & published status.
      }

      // 3. Merge with _allExams metadata and filter strictly to active &
      // published assessments assigned to this section.
      final byId = <int, Map<String, dynamic>>{};
      for (final e in _allExams) {
        final id = int.tryParse('${e['id']}');
        if (id != null) {
          byId[id] = Map<String, dynamic>.from(e);
        }
      }

      final activeExams = <Map<String, dynamic>>[];
      final seenIds = <int>{};

      for (final a in sectionAssessments) {
        final id = int.tryParse('${a['id']}');
        if (id == null) continue;
        final merged = <String, dynamic>{
          if (byId.containsKey(id)) ...byId[id]!,
          ...a,
        };
        if (_isActiveAndPublished(merged) &&
            !fullyCompletedExamIds.contains(id)) {
          final qCount = int.tryParse('${merged['question_count'] ?? 1}') ?? 1;
          if (qCount > 0 && seenIds.add(id)) {
            activeExams.add(merged);
          }
        }
      }

      // Fallback check across _allExams in case sectionAssessments was empty.
      for (final e in _allExams) {
        final id = int.tryParse('${e['id']}');
        if (id == null || seenIds.contains(id)) continue;
        if (_isActiveAndPublished(e) &&
            !fullyCompletedExamIds.contains(id) &&
            _examBelongsToClass(e, classId, sectionName)) {
          seenIds.add(id);
          activeExams.add(Map<String, dynamic>.from(e));
        }
      }

      if (!mounted) return;

      Map<String, dynamic>? chosenExam;
      if (preferredExamId != null) {
        for (final e in activeExams) {
          if (int.tryParse('${e['id']}') == preferredExamId) {
            chosenExam = e;
            break;
          }
        }
        if (chosenExam == null && byId.containsKey(preferredExamId) && byId[preferredExamId]!['creation_mode'] != 'manual') {
          final fallbackExam = Map<String, dynamic>.from(byId[preferredExamId]!);
          activeExams.insert(0, fallbackExam);
          chosenExam = fallbackExam;
        }
      }
      chosenExam ??= activeExams.isNotEmpty ? activeExams.first : null;

      // Keep the selected section's student count updated.
      if (sectionStudents.isNotEmpty && _selectedSection != null) {
        _selectedSection = {
          ..._selectedSection!,
          'students': sectionStudents.length,
        };
      }

      setState(() {
        _exams = activeExams;
        _selectedExam = chosenExam;
        _selectedExamStudents = sectionStudents;
        _isLoadingAssessments = false;
      });

      if (_selectedExam != null) {
        await _loadExamSections();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingAssessments = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load assessments for section: $e'),
        ),
      );
    }
  }

  // =========================
  // LOAD SELECTED EXAM DATA (SECTIONS, QUESTIONS, ACCEPTABLE ANSWERS, STUDENTS)
  // =========================

  Future<void> _loadExamSections() async {
    if (_selectedExam == null || _selectedExam!['creation_mode']=='manual') return;

    final int? examId = int.tryParse('${_selectedExam!['id']}');
    if (examId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid exam ID.')),
      );
      return;
    }

    setState(() {
      _isLoadingSections = true;
      _selectedExamSections = [];
    });

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Session expired. Please log in again.');
      }

      Map<String, dynamic> fullExam = Map<String, dynamic>.from(_selectedExam!);
      try {
        final detail = await ApiService.getExamById(token, examId);
        fullExam = {...fullExam, ...detail};
      } catch (_) {
        // Keep list metadata if detail endpoint fails.
      }

      // Stamp the selected Subject & Section onto fullExam so downstream
      // scanner and scorebook screens always use the selected section.
      final int? selectedClassId =
          int.tryParse('${_selectedSection?['class_id'] ?? ''}');
      final String selectedSectionName =
          (_selectedSection?['name']?.toString() ?? '').trim();
      final String selectedSubjCode =
          (_selectedSubject?['code']?.toString() ?? '').trim();
      final String selectedSubjName =
          (_selectedSubject?['name']?.toString() ?? '').trim();

      if (selectedClassId != null) {
        fullExam['class_id'] = selectedClassId;
        fullExam['class_ids'] = [selectedClassId];
      }
      if (selectedSectionName.isNotEmpty) {
        fullExam['selected_section'] = selectedSectionName;
      }
      if (selectedSubjCode.isNotEmpty) {
        fullExam['subject_code'] = selectedSubjCode;
      }
      if (selectedSubjName.isNotEmpty) {
        fullExam['subject_name'] = selectedSubjName;
      }

      final sections = await ApiService.getExamSections(token, examId);
      sections.sort((a, b) {
        final oa = int.tryParse('${a['section_order'] ?? 0}') ?? 0;
        final ob = int.tryParse('${b['section_order'] ?? 0}') ?? 0;
        if (oa != ob) return oa.compareTo(ob);
        final ia = int.tryParse('${a['id'] ?? 0}') ?? 0;
        final ib = int.tryParse('${b['id'] ?? 0}') ?? 0;
        return ia.compareTo(ib);
      });

      final List<Map<String, dynamic>> preparedSections = [];

      for (final section in sections) {
        final int? sectionId = int.tryParse('${section['id']}');
        if (sectionId == null) continue;

        final questions = await ApiService.getQuestions(token, sectionId);
        questions.sort((a, b) {
          final qa = int.tryParse('${a['question_number'] ?? 0}') ?? 0;
          final qb = int.tryParse('${b['question_number'] ?? 0}') ?? 0;
          if (qa != qb) return qa.compareTo(qb);
          final ia = int.tryParse('${a['id'] ?? 0}') ?? 0;
          final ib = int.tryParse('${b['id'] ?? 0}') ?? 0;
          return ia.compareTo(ib);
        });

        final normalizedType = _normalizeQuestionType(
          section['question_type'] ?? section['type'],
        );

        // Fetch acceptable answers for identification questions so client-side
        // live scoring matches backend grading.
        final enrichedQuestions = <Map<String, dynamic>>[];
        for (final q in questions) {
          final copy = Map<String, dynamic>.from(q);
          if (normalizedType == 'identification') {
            final qId = int.tryParse('${q['id']}');
            if (qId != null && copy['acceptable_answers'] == null) {
              try {
                final alts = await ApiService.getAcceptableAnswers(token, qId);
                copy['acceptable_answers'] = alts;
              } catch (_) {
                copy['acceptable_answers'] = const <Map<String, dynamic>>[];
              }
            }
          }
          enrichedQuestions.add(copy);
        }

        final preparedSection = Map<String, dynamic>.from(section);
        preparedSection['questions'] = enrichedQuestions;
        preparedSection['question_count'] = enrichedQuestions.length;
        preparedSection['question_type'] = normalizedType;
        preparedSection['display_name'] = _getSectionName(section);

        preparedSections.add(preparedSection);
      }

      // Load students strictly for the selected section (class_id).
      List<Map<String, dynamic>> students = [];
      try {
        if (selectedClassId != null) {
          students = await ApiService.getStudents(
            token,
            classId: selectedClassId,
          );
        } else {
          students = await ApiService.getExamStudents(token, fullExam);
        }
      } catch (_) {
        students = _selectedExamStudents;
      }

      if (!mounted) return;

      setState(() {
        _selectedExam = fullExam;
        _selectedExamSections = preparedSections;
        _selectedExamStudents = students;
        if (_selectedSection != null && selectedClassId != null) {
          _selectedSection = {
            ..._selectedSection!,
            'students': students.length,
          };
        }
        _isLoadingSections = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingSections = false;
        _selectedExamSections = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load exam sections: $e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  String _normalizeQuestionType(dynamic value) {
    final type = value?.toString().trim().toLowerCase() ?? '';
    switch (type) {
      case 'multiple_choice':
      case 'multiple choice':
      case 'mc':
      case 'mcq':
        return 'multiple_choice';
      case 'true_false':
      case 'true or false':
      case 'true/false':
      case 'true_false_question':
      case 'tf':
        return 'true_false';
      case 'identification':
      case 'identify':
      case 'id':
        return 'identification';
      default:
        return type;
    }
  }

  String _getSectionName(Map<String, dynamic> section) {
    final name = section['name'] ?? section['title'] ?? section['section_name'];
    if (name != null && name.toString().trim().isNotEmpty) {
      return name.toString();
    }
    return 'Section';
  }

  String _subjectDisplayLabel(Map<String, dynamic>? subject, [Map<String, dynamic>? exam]) {
    final code = (subject?['code'] ??
            exam?['subject_code'] ??
            (exam?['class'] is Map && (exam!['class'] as Map)['subject'] is Map
                ? ((exam['class'] as Map)['subject'] as Map)['code']
                : null))
        ?.toString()
        .trim() ??
        '';
    final name = (subject?['name'] ??
            exam?['subject_name'] ??
            (exam?['class'] is Map && (exam!['class'] as Map)['subject'] is Map
                ? ((exam['class'] as Map)['subject'] as Map)['name']
                : null))
        ?.toString()
        .trim() ??
        '';
    final parts = [code, name].where((e) => e.isNotEmpty).toList();
    return parts.join(' - ');
  }

  String _selectedSectionLabel([Map<String, dynamic>? exam]) {
    final fromSelected = (_selectedSection?['name']?.toString() ?? '').trim();
    if (fromSelected.isNotEmpty) return fromSelected;

    final fromExamSelected =
        (exam?['selected_section']?.toString() ?? '').trim();
    if (fromExamSelected.isNotEmpty) return fromExamSelected;

    final cls = exam?['class'];
    if (cls is Map) {
      final sec = (cls['section']?.toString() ?? '').trim();
      if (sec.isNotEmpty) return sec;
    }
    return '';
  }

  int _selectedSectionStudentCount() {
    if (_selectedExamStudents.isNotEmpty) {
      return _selectedExamStudents.length;
    }
    return int.tryParse('${_selectedSection?['students'] ?? 0}') ?? 0;
  }

  void _routeToMySubjects() {
    if (!mounted) return;
    final shell = context.findAncestorWidgetOfExactType<TeacherShell>();
    if (shell != null) {
      shell.onSelect(TeacherPage.subjects);
    }
  }

  // =========================
  // CONTINUE TO SCANNER (CAMERA OR FILE UPLOAD)
  // =========================

  Future<void> _continueToScanner({bool? forceUpload}) async {
    if (_selectedSubject == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a subject first.')),
      );
      return;
    }

    if (_selectedSection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a section first.')),
      );
      return;
    }

    if (_selectedExam == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an assessment first.')),
      );
      return;
    }

    if (_isLoadingSections) return;

    if (_selectedExamSections.isEmpty) {
      await _loadExamSections();
      if (!mounted || _selectedExamSections.isEmpty) return;
    }

    final int? examId = int.tryParse('${_selectedExam!['id']}');
    if (examId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid exam ID.')),
      );
      return;
    }

    final List<Map<String, dynamic>> scannerSections =
        _selectedExamSections.map((section) {
      return {
        'id': section['id'],
        'name': _getSectionName(section),
        'section_name': _getSectionName(section),
        'display_name': _getSectionName(section),
        'default_points': section['default_points'],
        'question_type': _normalizeQuestionType(section['question_type']),
        'question_count': section['question_count'] ?? 0,
        'questions': section['questions'] ?? [],
      };
    }).toList();

    final examMap = Map<String, dynamic>.from(_selectedExam!);
    final studentsList = List<Map<String, dynamic>>.from(_selectedExamStudents);

    final screenWidth = MediaQuery.sizeOf(context).width;
    final bool isMobileOrTablet = screenWidth < 1024;
    final bool useUploadScreen =
        forceUpload ?? (!isMobileOrTablet || kIsWeb);

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (routeContext) {
          if (useUploadScreen) {
            return AnswerSheetUploadScreen(
              examId: examId,
              exam: examMap,
              sections: scannerSections,
              students: studentsList,
              onViewInMySubjects: _routeToMySubjects,
            );
          }

          return AnswerSheetCameraScreen(
            examId: examId,
            exam: examMap,
            sections: scannerSections,
            students: studentsList,
            onViewInMySubjects: _routeToMySubjects,
          );
        },
      ),
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final bool isMobileOrTablet = screenWidth < 1024;

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kNavy,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Answer Sheet Scanner',
          style: TextStyle(
            color: _kNavy,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _kLine),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: _kNavy),
            )
          : RefreshIndicator(
              color: _kNavy,
              onRefresh: _loadExams,
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: screenWidth >= 900 ? 32 : 20,
                  vertical: 24,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Hero Header Card
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _kLine),
                              boxShadow: [
                                BoxShadow(
                                  color: _kNavy.withValues(alpha: 0.04),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: _kNavy.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Icon(
                                    Icons.document_scanner_outlined,
                                    size: 32,
                                    color: _kNavy,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Scan & Score Answer Sheets',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: _kNavy,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  isMobileOrTablet
                                      ? 'Select a subject, section, and active assessment, align the answer sheet corners in your camera frame, verify answers, and record scores directly to My Subjects.'
                                      : 'Select a subject, section, and active assessment, upload a JPG or PNG answer sheet scan, verify detected answers, and record scores directly to My Subjects.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: _kSlate,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                if (_subjects.isEmpty)
                                  _buildNoExamsState()
                                else
                                  _buildExamSelector(),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          if (_isLoadingSections)
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _kLine),
                              ),
                              child: const Row(
                                children: [
                                  SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _kNavy,
                                    ),
                                  ),
                                  SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      'Loading exam structure, answer keys, and enrolled students...',
                                      style: TextStyle(
                                        color: _kNavy,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          if (!_isLoadingSections &&
                              _selectedExam != null &&
                              _selectedExamSections.isNotEmpty) ...[
                            _buildExamStructureCard(),
                            const SizedBox(height: 20),
                          ],

                          if (_selectedExam != null) ...[
                            _buildCaptureMethodCard(isMobileOrTablet),
                            const SizedBox(height: 20),
                            _buildActionButtons(isMobileOrTablet),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildNoExamsState() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kLine),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.assignment_late_outlined,
            size: 44,
            color: _kSlate,
          ),
          const SizedBox(height: 12),
          const Text(
            'No subjects or assessments available yet.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _kNavy,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Assign a subject section and publish an assessment in My Subjects or Exams first before scanning answer sheets.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _kSlate),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _loadExams,
            style: OutlinedButton.styleFrom(
              foregroundColor: _kNavy,
              side: const BorderSide(color: _kLine),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  InputDecoration _dropdownDecoration({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: _kSlate, fontWeight: FontWeight.w600),
      filled: true,
      fillColor: _kBg,
      prefixIcon: Icon(icon, color: _kNavy),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _kLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _kLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _kNavy, width: 1.5),
      ),
    );
  }

  Widget _buildExamSelector() {
    // 1. Unique subjects keyed by subject['key']
    final uniqueSubjects = <Map<String, dynamic>>[];
    final seenSubjKeys = <String>{};
    for (final s in _subjects) {
      final k = (s['key'] ?? '${s['subject_id'] ?? s['code']}').toString();
      if (k.isNotEmpty && seenSubjKeys.add(k)) {
        uniqueSubjects.add(s);
      }
    }

    final String? selectedSubjectKey = _selectedSubject != null
        ? (_selectedSubject!['key'] ??
                '${_selectedSubject!['subject_id'] ?? _selectedSubject!['code']}')
            .toString()
        : null;
    final String? validSubjectKey =
        (selectedSubjectKey != null && seenSubjKeys.contains(selectedSubjectKey))
            ? selectedSubjectKey
            : null;

    // 2. Sections belonging to the selected subject
    final sections = _subjectSections(_selectedSubject);
    final uniqueSections = <Map<String, dynamic>>[];
    final seenClassIds = <int>{};
    for (final sec in sections) {
      final cid = int.tryParse('${sec['class_id']}');
      if (cid != null && seenClassIds.add(cid)) {
        uniqueSections.add(sec);
      }
    }

    final int? selectedClassId =
        int.tryParse('${_selectedSection?['class_id'] ?? ''}');
    final int? validClassId =
        (selectedClassId != null && seenClassIds.contains(selectedClassId))
            ? selectedClassId
            : null;

    // 3. Active & Published assessments for the selected section
    final uniqueExams = <Map<String, dynamic>>[];
    final seenExamIds = <int>{};
    for (final exam in _exams) {
      final id = int.tryParse('${exam['id']}');
      if (id != null && seenExamIds.add(id)) {
        uniqueExams.add(exam);
      }
    }

    final int? selectedExamId = int.tryParse('${_selectedExam?['id'] ?? ''}');
    final int? validSelectedExamId =
        (selectedExamId != null && seenExamIds.contains(selectedExamId))
            ? selectedExamId
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Step 1: Subject Filter
        DropdownButtonFormField<String>(
          key: ValueKey('subject-dd-$validSubjectKey-${uniqueSubjects.length}'),
          initialValue: validSubjectKey,
          isExpanded: true,
          decoration: _dropdownDecoration(
            label: 'Subject',
            hint: 'Select a subject',
            icon: Icons.menu_book_outlined,
          ),
          items: uniqueSubjects.map((subj) {
            final k =
                (subj['key'] ?? '${subj['subject_id'] ?? subj['code']}').toString();
            final label = _subjectDisplayLabel(subj);
            return DropdownMenuItem<String>(
              value: k,
              child: Text(
                label.isEmpty ? 'Subject' : label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _kNavy,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            );
          }).toList(),
          onChanged: (String? subjKey) {
            if (subjKey == null) return;
            Map<String, dynamic>? chosenSubj;
            for (final s in uniqueSubjects) {
              final k =
                  (s['key'] ?? '${s['subject_id'] ?? s['code']}').toString();
              if (k == subjKey) {
                chosenSubj = s;
                break;
              }
            }
            if (chosenSubj == null) return;
            setState(() {
              _selectedSubject = chosenSubj;
              _selectedSection = null;
              _exams = [];
              _selectedExam = null;
              _selectedExamSections = [];
              _selectedExamStudents = [];
            });
          },
        ),

        // Step 2: Section Filter (shown once a Subject is selected)
        if (_selectedSubject != null) ...[
          const SizedBox(height: 14),
          if (uniqueSections.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _kBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kLine),
              ),
              child: const Text(
                'No sections assigned to this subject yet.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _kSlate,
                ),
              ),
            )
          else
            DropdownButtonFormField<int>(
              key: ValueKey(
                'section-dd-$validSubjectKey-$validClassId-${uniqueSections.length}',
              ),
              initialValue: validClassId,
              isExpanded: true,
              decoration: _dropdownDecoration(
                label: 'Section',
                hint: 'Select a section',
                icon: Icons.groups_outlined,
              ),
              items: uniqueSections.map((sec) {
                final cid = int.parse('${sec['class_id']}');
                final secName = sec['name']?.toString().trim() ?? 'Section';
                return DropdownMenuItem<int>(
                  value: cid,
                  child: Text(
                    secName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _kNavy,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                );
              }).toList(),
              onChanged: (int? classId) async {
                if (classId == null) return;
                Map<String, dynamic>? chosenSec;
                for (final sec in uniqueSections) {
                  if (int.tryParse('${sec['class_id']}') == classId) {
                    chosenSec = sec;
                    break;
                  }
                }
                if (chosenSec == null) return;
                setState(() {
                  _selectedSection = chosenSec;
                  _exams = [];
                  _selectedExam = null;
                  _selectedExamSections = [];
                  _selectedExamStudents = [];
                });
                await _loadAssessmentsForSection(chosenSec);
              },
            ),
        ],

        // Step 3: Active & Published Assessment Selector (shown once a Section is selected)
        if (_selectedSection != null) ...[
          const SizedBox(height: 14),
          if (_isLoadingAssessments)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _kBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kLine),
              ),
              child: const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _kNavy,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Loading active & published assessments for this section...',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _kNavy,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (uniqueExams.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _kAmber.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kAmber.withValues(alpha: 0.35)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: _kAmber),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No active and published assessments needing scanning for this section.',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _kNavy,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            DropdownButtonFormField<int>(
              key: ValueKey(
                'assessment-dd-$validClassId-$validSelectedExamId-${uniqueExams.length}',
              ),
              initialValue: validSelectedExamId,
              isExpanded: true,
              decoration: _dropdownDecoration(
                label: 'Assessment',
                hint: 'Select an active assessment to scan',
                icon: Icons.assignment_outlined,
              ),
              items: uniqueExams.map((exam) {
                final examId = int.parse('${exam['id']}');
                final title = exam['title']?.toString() ?? 'Untitled Exam';
                return DropdownMenuItem<int>(
                  value: examId,
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _kNavy,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                );
              }).toList(),
              onChanged: (int? examId) async {
                if (examId == null) return;
                Map<String, dynamic>? chosen;
                for (final e in uniqueExams) {
                  if (int.tryParse('${e['id']}') == examId) {
                    chosen = e;
                    break;
                  }
                }
                if (chosen == null) return;
                setState(() {
                  _selectedExam = chosen;
                  _selectedExamSections = [];
                });
                await _loadExamSections();
              },
            ),
        ],
      ],
    );
  }

  Widget _buildExamStructureCard() {
    final exam = _selectedExam!;
    final subjectLabel = _subjectDisplayLabel(_selectedSubject, exam);
    final selectedSectionName = _selectedSectionLabel(exam);
    final studentCount = _selectedSectionStudentCount();
    final totalItems = _selectedExamSections.fold<int>(
      0,
      (sum, s) => sum + (int.tryParse('${s['question_count'] ?? 0}') ?? 0),
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
        boxShadow: [
          BoxShadow(
            color: _kNavy.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Assessment Structure & Roster',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _kNavy,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kEmerald.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$totalItems ${totalItems == 1 ? 'item' : 'items'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _kEmeraldDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (subjectLabel.isNotEmpty)
                _metaChip(Icons.menu_book_outlined, 'Subject: $subjectLabel'),
              if (selectedSectionName.isNotEmpty)
                _metaChip(
                  Icons.groups_outlined,
                  'Section: $selectedSectionName',
                ),
              _metaChip(
                Icons.people_outline,
                'No. of Students: $studentCount',
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: _kLine),
          ),
          ..._selectedExamSections.map((section) {
            final type = _normalizeQuestionType(section['question_type']);
            final count = section['question_count']?.toString() ?? '0';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _kBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kLine),
                    ),
                    child: Icon(
                      _sectionIcon(type),
                      size: 18,
                      color: _kNavy,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getSectionName(section),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: _kNavy,
                          ),
                        ),
                        Text(
                          _typeDescription(type),
                          style: const TextStyle(
                            fontSize: 12,
                            color: _kSlate,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _kBg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _kLine),
                    ),
                    child: Text(
                      '$count Qs',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: _kNavy,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _kSlate),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _kSlate,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureMethodCard(bool isMobileOrTablet) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _kNavy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isMobileOrTablet && !kIsWeb
                  ? Icons.photo_camera_outlined
                  : Icons.upload_file_outlined,
              size: 26,
              color: _kNavy,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMobileOrTablet && !kIsWeb
                      ? 'Mobile & Tablet Camera Capture (< 1024px)'
                      : 'Answer Sheet Image Upload & OMR Scanner',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _kNavy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isMobileOrTablet && !kIsWeb
                      ? 'Opens the full-screen viewfinder with corner alignment guides, 1x/2x zoom review, and gallery picker fallback.'
                      : 'Supports JPG and PNG answer sheet scans with automatic 4-corner marker registration and bubble detection.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: _kSlate,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(bool isMobileOrTablet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _isLoadingSections
              ? null
              : () => _continueToScanner(
                    forceUpload: kIsWeb ? !isMobileOrTablet : null,
                  ),
          icon: _isLoadingSections
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  (isMobileOrTablet && !kIsWeb)
                      ? Icons.camera_alt_outlined
                      : Icons.document_scanner_outlined,
                ),
          label: Text(
            _isLoadingSections
                ? 'Loading Assessment...'
                : (isMobileOrTablet && !kIsWeb)
                    ? 'Open Camera Scanner'
                    : 'Continue to Answer Sheet Scanner',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: _kNavyDark,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        if (!kIsWeb && isMobileOrTablet) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _isLoadingSections
                ? null
                : () => _continueToScanner(forceUpload: true),
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text(
              'Upload Answer Sheet Image Instead',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kNavy,
              side: const BorderSide(color: _kLine),
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
        if (_selectedExam != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: (_isDownloadingSheet || _isLoadingSections)
                ? null
                : _downloadAnswerSheet,
            icon: _isDownloadingSheet
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _kNavy,
                    ),
                  )
                : const Icon(Icons.download_outlined),
            label: Text(
              _isDownloadingSheet
                  ? 'Preparing 2xA5 Answer Sheets PDF...'
                  : 'Download Answer Sheet PDF',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kNavy,
              side: const BorderSide(color: _kLine),
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _typeDescription(String type) {
    switch (type) {
      case 'multiple_choice':
        return 'Multiple Choice | Bubbles A-D';
      case 'true_false':
        return 'True or False | Bubbles T / F';
      case 'identification':
        return 'Identification | CAPITAL LETTERS OCR / Manual';
      default:
        return type;
    }
  }

  // =========================
  // DOWNLOAD ANSWER SHEET
  // =========================

  Future<void> _downloadAnswerSheet() async {
    if (_selectedExam == null) return;

    final examId = int.tryParse(_selectedExam!['id'].toString());
    if (examId == null) return;

    setState(() => _isDownloadingSheet = true);

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exam = Map<String, dynamic>.from(_selectedExam!);
      final sections = await ApiService.getExamSections(token, examId);

      final questions = <int, List<Map<String, dynamic>>>{};
      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');
        if (sectionId == null) continue;
        questions[sectionId] = await ApiService.getQuestions(token, sectionId);
      }

      final int? selectedClassId =
          int.tryParse('${_selectedSection?['class_id'] ?? ''}');
      final students = _selectedExamStudents.isNotEmpty
          ? _selectedExamStudents
          : (selectedClassId != null
              ? await ApiService.getStudents(token, classId: selectedClassId)
              : await ApiService.getExamStudents(token, exam));

      final pdfBytes = await AnswerSheetPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
        students: students,
      );

      final title = (exam['title']?.toString() ?? 'exam')
          .trim()
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');

      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: 'answer_sheet_${title.isEmpty ? 'exam' : title}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isDownloadingSheet = false);
      }
    }
  }

  IconData _sectionIcon(String type) {
    switch (type) {
      case 'multiple_choice':
        return Icons.radio_button_checked;
      case 'true_false':
        return Icons.check_circle_outline;
      case 'identification':
        return Icons.edit_note;
      default:
        return Icons.help_outline;
    }
  }
}