import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';

class ColorResult {
  final String dominantColor;
  final List<String> allColors;
  final String description;
  final Color displayColor;

  ColorResult({
    required this.dominantColor,
    required this.allColors,
    required this.description,
    required this.displayColor,
  });
}

class ColorService {
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY'; 

  // ✅ Lite first (higher free quota), flash as fallback
  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  String? _workingModel;

  Future<ColorResult?> identifyColor(Uint8List imageBytes) async {
    // Use cached working model first
    if (_workingModel != null) {
      try {
        return await _callModel(_workingModel!, imageBytes);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') || msg.contains('429') ||
            msg.contains('rate')) {
          _workingModel = null; // reset and try next model
        } else {
          rethrow;
        }
      }
    }

    // Try each model until one works
    for (final model in _models) {
      try {
        print('🔄 Trying: $model');
        final result = await _callModel(model, imageBytes);
        if (result != null) {
          _workingModel = model;
          print('✅ Using: $model');
          return result;
        }
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('quota') || msg.contains('429') ||
            msg.contains('rate')) {
          print('⏳ Quota hit on $model, trying next...');
          continue;
        }
        rethrow;
      }
    }

    throw Exception(
        'All models quota exceeded. Please wait and try again.');
  }

  Future<ColorResult?> _callModel(
      String model, Uint8List imageBytes) async {
    final base64Image = base64Encode(imageBytes);

    const prompt = '''
Look at the CENTER of this image.
What is the single most dominant color of the main object?

Reply with ONLY one of these base colors:
red, orange, yellow, green, blue, purple, pink, brown, black, white, grey, beige, gold, silver, teal

Then optionally add ONE shade word before it: dark, light, bright, deep, pale, neon.

Rules:
- Reply with ONLY 1 to 3 words
- No sentences, no punctuation, no explanation
- Examples: "red", "dark blue", "light green", "bright yellow", "pale pink"
- If unsure between two colors, pick the most obvious one
''';

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
        'temperature': 0.0,
        'maxOutputTokens': 10,
      },
    });

    final url =
        Uri.parse('$_baseUrl/$model:generateContent?key=$_apiKey');

    print('📡 POST → $model');
    final response = await http
        .post(url,
            headers: {'Content-Type': 'application/json'},
            body: body)
        .timeout(const Duration(seconds: 20));

    print('📥 ${response.statusCode} ← $model');
    print('📄 Body: ${response.body}');

    // Quota hit
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
      print('⚠️ No candidates');
      return null;
    }

    final finishReason =
        candidates[0]['finishReason']?.toString() ?? '';
    print('🏁 Finish: $finishReason');
    if (finishReason == 'SAFETY') {
      print('🔒 Safety block');
      return null;
    }

    final parts = candidates[0]?['content']?['parts'];
    if (parts == null || parts is! List || parts.isEmpty) {
      print('⚠️ No parts');
      return null;
    }

    // Extract raw text
    String rawColor = parts
        .where((p) => p != null && p['text'] != null)
        .map((p) => p['text'].toString())
        .join(' ')
        .trim()
        .toLowerCase();

    print('🎨 Raw: "$rawColor"');

    // Clean sentence fragments model might add
    rawColor = rawColor
        .replaceAll(
            RegExp(
                r'the (main |dominant |primary )?color (of .+)?is\s*',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'[.!?,]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    print('🎨 Cleaned: "$rawColor"');

    if (rawColor.isEmpty || rawColor.length < 2) {
      print('⚠️ Too short');
      return null;
    }

    // Validate must contain known color word
    final validated = _validateColor(rawColor);
    if (validated == null) {
      print('⚠️ Not a valid color: "$rawColor"');
      return null;
    }

    print('✅ Validated: "$validated"');

    final displayColor = colorFromName(validated);
    final spoken =
        validated[0].toUpperCase() + validated.substring(1);

    return ColorResult(
      dominantColor: validated,
      allColors: [validated],
      description: spoken,
      displayColor: displayColor,
    );
  }

  String? _validateColor(String text) {
    const baseColors = [
      'red', 'orange', 'yellow', 'green', 'blue', 'purple',
      'pink', 'brown', 'black', 'white', 'grey', 'gray',
      'beige', 'gold', 'silver', 'teal', 'cyan', 'navy',
      'maroon', 'olive', 'magenta', 'coral', 'cream', 'indigo',
      'violet', 'turquoise', 'peach', 'lavender', 'mint',
      'charcoal', 'ivory', 'tan', 'khaki',
    ];

    const shades = [
      'dark', 'light', 'bright', 'deep', 'pale',
      'soft', 'neon', 'vivid',
    ];

    final lower = text.toLowerCase();
    for (final c in baseColors) {
      if (lower.contains(c)) {
        for (final s in shades) {
          if (lower.contains('$s $c')) return '$s $c';
        }
        return c;
      }
    }
    return null;
  }

  Color colorFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('red')) return const Color(0xFFE53935);
    if (n.contains('orange')) return const Color(0xFFFB8C00);
    if (n.contains('yellow')) return const Color(0xFFFDD835);
    if (n.contains('green')) return const Color(0xFF43A047);
    if (n.contains('navy') || n.contains('indigo'))
      return const Color(0xFF1A237E);
    if (n.contains('blue')) return const Color(0xFF1E88E5);
    if (n.contains('purple') || n.contains('violet'))
      return const Color(0xFF8E24AA);
    if (n.contains('pink') || n.contains('magenta'))
      return const Color(0xFFE91E8C);
    if (n.contains('brown') || n.contains('maroon'))
      return const Color(0xFF6D4C41);
    if (n.contains('black') || n.contains('charcoal'))
      return const Color(0xFF212121);
    if (n.contains('white') || n.contains('ivory') ||
        n.contains('cream')) return const Color(0xFFFAFAFA);
    if (n.contains('grey') || n.contains('gray') ||
        n.contains('silver')) return const Color(0xFF757575);
    if (n.contains('teal') || n.contains('cyan') ||
        n.contains('turquoise')) return const Color(0xFF00897B);
    if (n.contains('beige') || n.contains('tan') ||
        n.contains('khaki')) return const Color(0xFFD7CCC8);
    if (n.contains('gold')) return const Color(0xFFFFB300);
    if (n.contains('coral') || n.contains('peach'))
      return const Color(0xFFFF7043);
    if (n.contains('mint') || n.contains('olive'))
      return const Color(0xFF66BB6A);
    if (n.contains('lavender')) return const Color(0xFF9575CD);
    return const Color(0xFF9E9E9E);
  }
}