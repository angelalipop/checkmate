class AnswerSheetLayout {
  AnswerSheetLayout._();

  static const double sheetWidth = 397.0;
  static const double sheetHeight = 559.0;
  static const double sheetPadding = 10.0;

  static const double bubbleSize = 11.0;
  static const double answerOptionWidth = 23.0;
  static const double questionNumberWidth = 17.0;
  static const double omrRowHeight = 17.0;

  static const double identificationBoxHeight = 18.0;
  static const double identificationRowSpacing = 3.0;

  static const double sectionTitleHeight = 18.0;
  static const double sectionTitleGap = 3.0;
  static const double sectionSpacing = 5.0;

  static const double firstSectionY = 105.0;

  static int calculateOmrColumns(int questionCount) {
    return questionCount >= 10 ? 2 : 1;
  }
}
