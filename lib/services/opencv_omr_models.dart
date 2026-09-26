import 'dart:convert';
import 'dart:typed_data';

class OpenCVBubbleMeasurement {
  final String label;
  final double fillRatio;

  const OpenCVBubbleMeasurement({
    required this.label,
    required this.fillRatio,
  });

  factory OpenCVBubbleMeasurement.fromJson(Map<String, dynamic> json) {
    return OpenCVBubbleMeasurement(
      label: json['label']?.toString() ?? '',
      fillRatio: (json['fillRatio'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'fillRatio': fillRatio,
      };
}

class OpenCVQuestionMeasurement {
  final int questionNumber;
  final List<OpenCVBubbleMeasurement> bubbles;

  const OpenCVQuestionMeasurement({
    required this.questionNumber,
    required this.bubbles,
  });

  factory OpenCVQuestionMeasurement.fromJson(Map<String, dynamic> json) {
    final raw = json['bubbles'];
    return OpenCVQuestionMeasurement(
      questionNumber: (json['questionNumber'] as num?)?.toInt() ?? 0,
      bubbles: raw is List
          ? raw
              .whereType<Map>()
              .map((item) => OpenCVBubbleMeasurement.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : <OpenCVBubbleMeasurement>[],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'questionNumber': questionNumber,
        'bubbles': bubbles.map((bubble) => bubble.toJson()).toList(),
      };
}

class OpenCVSectionMeasurement {
  final String sectionName;
  final String sectionType;
  final List<OpenCVQuestionMeasurement> questions;

  const OpenCVSectionMeasurement({
    required this.sectionName,
    required this.sectionType,
    required this.questions,
  });

  factory OpenCVSectionMeasurement.fromJson(Map<String, dynamic> json) {
    final raw = json['questions'];
    return OpenCVSectionMeasurement(
      sectionName: json['sectionName']?.toString() ?? 'Section',
      sectionType: json['sectionType']?.toString() ?? '',
      questions: raw is List
          ? raw
              .whereType<Map>()
              .map((item) => OpenCVQuestionMeasurement.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : <OpenCVQuestionMeasurement>[],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sectionName': sectionName,
        'sectionType': sectionType,
        'questions': questions.map((question) => question.toJson()).toList(),
      };
}

class OpenCVOMRResult {
  final List<OpenCVSectionMeasurement> sections;
  final Uint8List? debugImageBytes;

  const OpenCVOMRResult({
    required this.sections,
    required this.debugImageBytes,
  });

  factory OpenCVOMRResult.fromJson(Map<String, dynamic> json) {
    final rawSections = json['sections'];
    final debugBase64 = json['debugImageBase64']?.toString();

    return OpenCVOMRResult(
      sections: rawSections is List
          ? rawSections
              .whereType<Map>()
              .map((item) => OpenCVSectionMeasurement.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList()
          : <OpenCVSectionMeasurement>[],
      debugImageBytes: debugBase64 == null || debugBase64.isEmpty
          ? null
          : base64Decode(debugBase64),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sections': sections.map((section) => section.toJson()).toList(),
        'debugImageBase64': debugImageBytes == null
            ? null
            : base64Encode(debugImageBytes!),
      };
}
