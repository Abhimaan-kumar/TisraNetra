import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';

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
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY';
  late final GenerativeModel _model;

  CurrencyService() {
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: _apiKey,
      generationConfig: GenerationConfig(
        temperature: 0.1,
        maxOutputTokens: 300,
      ),
    );
  }

  Future<CurrencyDetectionResult?> detectCurrency(Uint8List imageBytes) async {
    try {
      const prompt = '''
Look at this image carefully. Your job is to find any Indian Rupee currency notes.

Indian currency notes have these denominations: 10, 20, 50, 100, 200, 500, 2000.

Instructions:
- Look for ANY paper money, banknotes, or currency in the image
- Even if notes are partially visible, crumpled, or at an angle — still detect them
- If you see a note but cannot read the denomination clearly, make your best guess
- Count each note separately (e.g. two ₹500 notes = [500, 500])
- If truly no currency at all, notes array should be empty

You MUST respond with ONLY this JSON format, no explanation, no markdown:
{"notes": [500, 100], "total": 600}

If no currency found:
{"notes": [], "total": 0}
''';

      final response = await _model.generateContent([
        Content.multi([
          DataPart(
            'image/jpeg',
            imageBytes,
          ), // ← raw bytes, NOT base64Decode(base64Encode(...))
          TextPart(prompt),
        ]),
      ]);

      final text = response.text?.trim() ?? '';
      print('Gemini raw response: $text');

      if (text.isEmpty) {
        return CurrencyDetectionResult(
          detectedNotes: [],
          totalAmount: 0,
          rawResponse: 'Empty response',
        );
      }

      String jsonStr = text.replaceAll(RegExp(r'```json|```'), '').trim();
      final jsonMatch = RegExp(r'\{[^{}]*\}').firstMatch(jsonStr);

      if (jsonMatch == null) {
        print('Could not extract JSON from: $jsonStr');
        return CurrencyDetectionResult(
          detectedNotes: [],
          totalAmount: 0,
          rawResponse: text,
        );
      }

      final jsonData = jsonDecode(jsonMatch.group(0)!);
      final notes = List<int>.from(
        (jsonData['notes'] ?? []).map((n) => int.tryParse(n.toString()) ?? 0),
      ).where((n) => n > 0).toList();

      final total = notes.fold(0, (sum, n) => sum + n);

      return CurrencyDetectionResult(
        detectedNotes: notes,
        totalAmount: total,
        rawResponse: text,
      );
    } catch (e, stack) {
      print('Currency detection error: $e');
      print('Stack: $stack');
      rethrow;
    }
  }
}
