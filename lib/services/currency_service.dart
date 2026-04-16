import 'dart:math';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class CurrencyDetectionResult {
  final List<int> detectedNotes;
  final int totalAmount;
  final String rawResponse;

  CurrencyDetectionResult({
    required this.detectedNotes,
    required this.totalAmount,
    required this.rawResponse,
  });
}

class CurrencyService {
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  static const List<int> _denominations = [2000, 500, 200, 100, 50, 20, 10];

  Future<CurrencyDetectionResult?> detectCurrency(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      print('Offline Currency OCR Raw: \n${recognizedText.text}');

      final detectedNotes = <int>[];
      final seenCenters = <Point<int>>[]; 
      
      // Strategy 1: Look for explicit numerical blocks matching standard denominations
      for (TextBlock block in recognizedText.blocks) {
         // Clean noise, leave numbers
         final text = block.text.replaceAll(RegExp(r'[^0-9]'), '');
         if (text.isEmpty) continue;
         
         final val = int.tryParse(text);
         if (val != null && _denominations.contains(val)) {
            // Group by physical closeness to avoid counting the same note twice 
            // since a note has its number printed multiple times.
            final center = Point<int>(
              ((block.boundingBox.left + block.boundingBox.right) / 2).toInt(),
              ((block.boundingBox.top + block.boundingBox.bottom) / 2).toInt(),
            );
            
            bool isNewNote = true;
            for (int i = 0; i < detectedNotes.length; i++) {
               if (detectedNotes[i] == val) {
                  final p2 = seenCenters[i];
                  // Distance heuristic. If text blocks are close, they belong to the same note.
                  final dist = sqrt(pow(center.x - p2.x, 2) + pow(center.y - p2.y, 2));
                  if (dist < 400) { 
                     isNewNote = false;
                     break;
                  }
               }
            }
            
            if (isNewNote) {
               detectedNotes.add(val);
               seenCenters.add(center);
            }
         }
      }
      
      // Strategy 2: Fallback to text matching if numeric blocks are dirty/missed
      if (detectedNotes.isEmpty) {
         final raw = recognizedText.text.toLowerCase();
         if (raw.contains('two thousand')) detectedNotes.add(2000);
         else if (raw.contains('five hundred')) detectedNotes.add(500);
         else if (raw.contains('two hundred')) detectedNotes.add(200);
         else if (raw.contains('one hundred')) detectedNotes.add(100);
         else if (raw.contains('fifty rupees')) detectedNotes.add(50);
         else if (raw.contains('twenty rupees')) detectedNotes.add(20);
         else if (raw.contains('ten rupees')) detectedNotes.add(10);
      }
      
      final total = detectedNotes.fold(0, (sum, n) => sum + n);
      
      return CurrencyDetectionResult(
        detectedNotes: detectedNotes,
        totalAmount: total,
        rawResponse: recognizedText.text,
      );
    } catch (e) {
      print('Currency offline detection error: $e');
      rethrow;
    }
  }

  void dispose() {
    _textRecognizer.close();
  }
}
