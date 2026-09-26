class AnswerSheetLayout {
  AnswerSheetLayout._();

  // A5-style logical sheet dimensions used by both PDF generation and OMR.
  static const double sheetWidth = 397.0;
  static const double sheetHeight = 559.0;
  static const double sheetPadding = 10.0;

  // Registration markers.
  static const double registrationMarkerSize = 10.0;
  static const double registrationMarkerInset = 2.0;

  // OMR geometry.
  static const double bubbleSize = 11.0;
  static const double answerOptionWidth = 23.0;
  static const double questionNumberWidth = 17.0;
  static const double omrRowHeight = 17.0;

  // Identification geometry.
  static const double identificationBoxHeight = 18.0;
  static const double identificationRowSpacing = 3.0;

  // Section geometry.
  static const double sectionTitleHeight = 18.0;
  static const double sectionTitleGap = 3.0;
  static const double sectionSpacing = 5.0;

  // The main content starts at sheetPadding. Header/student information plus
  // its rendered gaps consume 95 logical units after that point, so the first
  // section begins at logical Y = 105.
  static const double firstSectionY = 105.0;

  static int calculateOmrColumns(int questionCount) {
    return questionCount >= 10 ? 2 : 1;
  }

  static double calculateSectionHeight({
    required String type,
    required int questionCount,
  }) {
    if (type == 'multiple_choice' || type == 'true_false') {
      final columns = calculateOmrColumns(questionCount);
      final rows = (questionCount / columns).ceil();

      return sectionTitleHeight +
          sectionTitleGap +
          (rows * omrRowHeight) +
          sectionSpacing;
    }

    if (type == 'identification') {
      return sectionTitleHeight +
          sectionTitleGap +
          (questionCount *
              (identificationBoxHeight + identificationRowSpacing)) +
          sectionSpacing;
    }

    return 30.0;
  }
}
