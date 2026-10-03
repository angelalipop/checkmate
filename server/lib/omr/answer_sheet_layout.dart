class AnswerSheetLayout {
  AnswerSheetLayout._();

  static const double sheetWidth = 397;
  static const double sheetHeight = 559;
  static const double sheetPadding = 10;

  static const double bubbleSize = 11;
  static const double answerOptionWidth = 23;
  static const double questionNumberWidth = 17;
  static const double omrRowHeight = 17;

  static const double identificationBoxHeight = 18;
  static const double identificationRowSpacing = 3;

  static const double sectionTitleHeight = 18;
  static const double sectionTitleGap = 3;
  static const double sectionSpacing = 5;

  static const double firstSectionY = 105;

  static int calculateOmrColumns(int questionCount) {
    return questionCount >= 10 ? 2 : 1;
  }
}
