import 'dart:typed_data';

import 'document_scanner_models.dart';

class DocumentScannerService {
  static Future<DocumentScanResult> process(Uint8List imageBytes) async {
    throw UnsupportedError(
      'Web document scanning will be connected to the '
      'CheckMate Docker backend in the next step.',
    );
  }
}
