class AnswerSheetLayout {
  AnswerSheetLayout._();

  static const double sheetWidth = 397;
  static const double sheetHeight = 559;
  static const double sheetPadding = 24;

  static const double bubbleSize = 11;
  static const double answerOptionWidth = 23;
  static const double questionNumberWidth = 17;
  static const double omrRowHeight = 19;

  static const double identificationBoxHeight = 18;
  static const double identificationRowSpacing = 3;

  static const double sectionTitleHeight = 18;
  static const double sectionTitleGap = 3;
  static const double sectionSpacing = 0;

  static const double firstSectionY = 129.0;
  static const double omrHeaderHeight = 10.0;
  static int calculateOmrColumns(int questionCount) {
    return questionCount >= 10 ? 2 : 1;
  }
}
