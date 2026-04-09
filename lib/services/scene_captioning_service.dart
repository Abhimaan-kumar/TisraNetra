import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class SceneCaptioningResult {
  final String caption;
  final String environment;

  SceneCaptioningResult({
    required this.caption,
    required this.environment,
  });

  bool isSimilarTo(SceneCaptioningResult? other) {
    if (other == null) return false;
    final wordsA = caption.toLowerCase().split(' ').toSet();
    final wordsB = other.caption.toLowerCase().split(' ').toSet();
    if (wordsA.isEmpty || wordsB.isEmpty) return false;
    final overlap = wordsA.intersection(wordsB).length;
    return (overlap / wordsA.length) > 0.65;
  }
}

class SceneCaptioningService {
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY'; // 🔑 your key

  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  String? _workingModel;

  Future<SceneCaptioningResult?> captureSceneCaptioning(Uint8List imageBytes) async {
    if (_workingModel != null) {
      try {
        return await _callModel(_workingModel!, imageBytes);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') || msg.contains('429') ||
            msg.contains('rate')) {
          _workingModel = null;
        } else {
          rethrow;
        }
      }
    }

    for (final model in _models) {
      try {
        print('Trying: $model');
        final result = await _callModel(model, imageBytes);
        if (result != null) {
          _workingModel = model;
          print('Using: $model');
          return result;
        }
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') || msg.contains('429') ||
            msg.contains('rate')) {
          print('Quota hit on $model, trying next...');
          continue;
        }
        rethrow;
      }
    }

    throw Exception('All models quota exceeded. Please wait.');
  }

  Future<SceneCaptioningResult?> _callModel(
      String model, Uint8List imageBytes) async {
    final base64Image = base64Encode(imageBytes);

    // Simple plain text prompt — no JSON, just describe the scene
    const prompt =
        'You are helping a blind person understand what is in front of them. '
        'Look at this image and describe the scene in 1-2 short sentences. '
        'Start directly with what you see. '
        'Be specific about objects, people, and setting. '
        'Keep it under 30 words. '
        'Example: "A busy street with cars and people walking on the pavement. '
        'There are shops on both sides." '
        'Do not say "I see" or "The image shows". Just describe directly.';

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
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 80,
      },
    });

    final url =
        Uri.parse('$_baseUrl/$model:generateContent?key=$_apiKey');

    print('POST → $model');
    final response = await http
        .post(url,
            headers: {'Content-Type': 'application/json'},
            body: body)
        .timeout(const Duration(seconds: 20));

    print('${response.statusCode} ← $model');
    print('Body: ${response.body}');

    if (response.statusCode == 429 ||
        (response.statusCode != 200 &&
            response.body.contains('quota'))) {
      throw Exception('Quota exceeded for $model. ${response.body}');
    }

    if (response.statusCode != 200) {
      final err = jsonDecode(response.body);
      throw Exception(
          err['error']?['message'] ?? 'HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body);

    final candidates = json['candidates'];
    if (candidates == null ||
        candidates is! List ||
        candidates.isEmpty) {
      print('No candidates');
      return null;
    }

    final finishReason =
        candidates[0]['finishReason']?.toString() ?? '';
    print('Finish: $finishReason');
    if (finishReason == 'SAFETY') {
      print('Safety block');
      return null;
    }

    final parts = candidates[0]?['content']?['parts'];
    if (parts == null || parts is! List || parts.isEmpty) {
      print('No parts');
      return null;
    }

    final caption = parts
        .where((p) => p != null && p['text'] != null)
        .map((p) => p['text'].toString())
        .join(' ')
        .trim();

    print('Caption: "$caption"');

    if (caption.isEmpty) return null;

    // Detect environment type from caption
    final environment = _detectEnvironment(caption);

    return SceneCaptioningResult(
      caption: caption,
      environment: environment,
    );
  }

  String _detectEnvironment(String caption) {
    final lower = caption.toLowerCase();
    if (lower.contains('road') || lower.contains('street') ||
        lower.contains('traffic') || lower.contains('car') ||
        lower.contains('vehicle')) return 'outdoor road';
    if (lower.contains('shop') || lower.contains('store') ||
        lower.contains('market') || lower.contains('mall'))
      return 'shopping area';
    if (lower.contains('kitchen') || lower.contains('food') ||
        lower.contains('dining') || lower.contains('restaurant'))
      return 'kitchen/dining';
    if (lower.contains('office') || lower.contains('desk') ||
        lower.contains('computer') || lower.contains('laptop'))
      return 'office/workspace';
    if (lower.contains('park') || lower.contains('garden') ||
        lower.contains('tree') || lower.contains('grass') ||
        lower.contains('outdoor')) return 'outdoor nature';
    if (lower.contains('bedroom') || lower.contains('bed') ||
        lower.contains('pillow')) return 'bedroom';
    if (lower.contains('bathroom') || lower.contains('toilet') ||
        lower.contains('sink')) return 'bathroom';
    if (lower.contains('hall') || lower.contains('corridor') ||
        lower.contains('stair')) return 'hallway';
    if (lower.contains('living') || lower.contains('sofa') ||
        lower.contains('couch') || lower.contains('tv'))
      return 'living room';
    if (lower.contains('person') || lower.contains('people') ||
        lower.contains('man') || lower.contains('woman') ||
        lower.contains('child')) return 'people nearby';
    return 'indoor space';
  }
}