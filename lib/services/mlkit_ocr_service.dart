import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

class MlKitOcrService {
  static Future<String> extractTextFromBytes(Uint8List imageBytes) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/checkmate_mlkit_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(imageBytes, flush: true);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
      return result.text;
    } finally {
      await recognizer.close();
      if (await file.exists()) await file.delete();
    }
  }
}
