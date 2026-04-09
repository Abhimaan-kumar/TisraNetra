import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class ObjectRecognitionResult {
  final String description;
  final List<String> objects;

  ObjectRecognitionResult({
    required this.description,
    required this.objects,
  });

  bool isSimilarTo(ObjectRecognitionResult? other) {
    if (other == null) return false;
    final wordsA = description.toLowerCase().split(' ').toSet();
    final wordsB = other.description.toLowerCase().split(' ').toSet();
    if (wordsA.isEmpty || wordsB.isEmpty) return false;
    final overlap = wordsA.intersection(wordsB).length;
    return (overlap / wordsA.length) > 0.6;
  }
}

class ObjectRecognitionService {
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY'; // 🔑 your key

  // ✅ Model fallback list — tries each until one works for your API key
  static const List<String> _models = [
    'gemini-2.5-flash-lite',        // newest lite, recommended
    'gemini-2.5-flash',             // full flash, also works
    'gemini-2.5-flash-preview-04-17', // preview fallback
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  // ✅ Simplest possible prompt — plain English, no JSON
  static const String _prompt =
      'Look at this image. In one sentence starting with "I can see", '
      'list the main objects visible. Be brief, max 20 words. '
      'Example: "I can see a chair, a table, and a laptop."';

  String? _workingModel; // caches the first model that works

  Future<ObjectRecognitionResult?> recognizeObjects(
      Uint8List imageBytes) async {
    // If we already found a working model, use it directly
    if (_workingModel != null) {
      return _callModel(_workingModel!, imageBytes);
    }

    // Try each model until one works
    for (final model in _models) {
      print('🔄 Trying model: $model');
      try {
        final result = await _callModel(model, imageBytes);
        if (result != null) {
          _workingModel = model;
          print('✅ Working model found: $model');
          return result;
        }
      } catch (e) {
        print('⚠️ Model $model failed: $e');
        continue; // try next model
      }
    }

    print('❌ All models failed');
    return null;
  }

  Future<ObjectRecognitionResult?> _callModel(
      String model, Uint8List imageBytes) async {
    final base64Image = base64Encode(imageBytes);
    final url = '$_baseUrl/$model:generateContent?key=$_apiKey';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            },
            {'text': _prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 60,
      },
    });

    print('📡 POST → $model');
    final response = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 20));

    print('📥 ${response.statusCode} ← $model');

    if (response.statusCode == 404 || response.statusCode == 403) {
      // This model not available for this key — try next
      print('🚫 $model not available (${response.statusCode})');
      throw Exception('Model not available: ${response.statusCode}');
    }

    if (response.statusCode != 200) {
      final err = jsonDecode(response.body);
      final msg = err['error']?['message'] ?? 'HTTP ${response.statusCode}';
      print('❌ API error: $msg');
      throw Exception(msg);
    }

    // ✅ Parse the plain text response
    final json = jsonDecode(response.body);
    print('📄 Response: ${response.body.substring(0, response.body.length.clamp(0, 400))}');

    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      print('⚠️ No candidates');
      // Check for block reason
      final feedback = json['promptFeedback'];
      if (feedback != null) print('🔒 Blocked: $feedback');
      return null;
    }

    final parts = candidates[0]?['content']?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      print('⚠️ No parts');
      return null;
    }

    // Collect all text parts
    final description = parts
        .map((p) => (p['text'] ?? '').toString())
        .where((t) => t.isNotEmpty)
        .join(' ')
        .trim();

    print('💬 Got description: "$description"');

    if (description.isEmpty) return null;

    return ObjectRecognitionResult(
      description: description,
      objects: _parseObjects(description),
    );
  }

  List<String> _parseObjects(String text) {
    // Strip leading "I can see" and split by comma/and
    final cleaned = text
        .replaceAll(RegExp(r'^i can see\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\.\s*$'), '');

    return cleaned
        .split(RegExp(r',\s*|\s+and\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s.split(' ').length <= 5)
        .toList();
  }
}