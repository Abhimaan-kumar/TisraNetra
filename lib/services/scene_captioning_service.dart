import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'language_preference_service.dart';

class SceneCaptioningResult {
  final String caption;
  final String environment;

  SceneCaptioningResult({
    required this.caption,
    required this.environment,
  });

  String get environmentLabel {
    final isHindi = LanguagePreferenceService().isHindi;
    if (!isHindi) return environment;
    switch (environment.toLowerCase()) {
      case 'outdoor road': return 'बाहरी सड़क';
      case 'shopping area': return 'दुकान या बाज़ार';
      case 'kitchen/dining': return 'रसोई या भोजन क्षेत्र';
      case 'office/workspace': return 'कार्यालय या कार्यक्षेत्र';
      case 'outdoor nature': return 'बाहरी प्रकृति या पार्क';
      case 'bedroom': return 'शयनकक्ष';
      case 'bathroom': return 'स्नानघर';
      case 'hallway': return 'गलियारा';
      case 'living room': return 'बैठक कक्ष';
      case 'people nearby': return 'आसपास के लोग';
      case 'indoor space': default: return 'भीतरी स्थान';
    }
  }

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
  static const String _apiKey = String.fromEnvironment(
    'GEMINI_VISION_API_KEY',
    defaultValue: String.fromEnvironment('GEMINI_API_KEY'),
  );

  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  String? _workingModel;

  Future<SceneCaptioningResult?> captureSceneCaptioning(List<Uint8List> imagesBytesList) async {
    if (imagesBytesList.isEmpty) return null;
    if (_workingModel != null) {
      try {
        return await _callModel(_workingModel!, imagesBytesList);
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
        final result = await _callModel(model, imagesBytesList);
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
      String model, List<Uint8List> imagesBytesList) async {
    final List<Map<String, dynamic>> parts = [];

    for (final bytes in imagesBytesList) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(bytes),
        }
      });
    }

    final isHindi = LanguagePreferenceService().isHindi;
    final prompt = isHindi
        ? 'आप एक दृष्टिबाधित व्यक्ति की मदद कर रहे हैं उनके आस-पास के वातावरण को समझने में। '
          'इन 3 छवियों को देखें और पूरे दृश्य का 1-2 छोटे वाक्यों में विस्तृत वर्णन करें। '
          'तीनों छवियों के विवरण को मिलाकर उनके सामने और आस-पास का पूरा माहौल बताएं। '
          'जो कुछ भी आप देख रहे हैं, सीधे उससे शुरुआत करें। '
          'वस्तुओं, लोगों और परिवेश के बारे में विशिष्ट विवरण दें। '
          'इसे 30 शब्दों से कम में रखें। '
          'उदाहरण: "सड़क पर कारों और फुटपाथ पर चलने वाले लोगों के साथ एक व्यस्त सड़क है। दोनों तरफ दुकानें हैं।" '
          'यह कभी न कहें कि "मैं देख रहा हूँ" या "छवि दिखाती है" या "पहली छवि में"। केवल सीधा और सटीक वर्णन करें।'
        : 'You are helping a blind person understand their surrounding environment. '
          'Look at these 3 image frames of the surroundings and describe the overall scene in 1-2 short sentences. '
          'Combine details across all 3 frames to provide a complete context of what is in front and around them. '
          'Start directly with what you see. '
          'Be specific about objects, people, and setting. '
          'Keep it under 30 words. '
          'Example: "A busy street with cars and people walking on the pavement. There are shops on both sides." '
          'Do not say "I see", "The image shows", or "In frame 1". Just describe directly.';

    parts.add({'text': prompt});

    final body = jsonEncode({
      'contents': [
        {
          'parts': parts,
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

    final resParts = candidates[0]?['content']?['parts'];
    if (resParts == null || resParts is! List || resParts.isEmpty) {
      print('No parts');
      return null;
    }

    final caption = resParts
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