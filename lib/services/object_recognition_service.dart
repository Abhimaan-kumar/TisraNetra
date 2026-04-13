import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

// ── Detected object with normalized bounding box ─────────────────────────────
// All coords are 0.0–1.0 (fraction of image width/height)

class DetectedObject {
  final String name;
  final double left;   // x of top-left corner (0.0–1.0)
  final double top;    // y of top-left corner (0.0–1.0)
  final double width;  // box width  (0.0–1.0)
  final double height; // box height (0.0–1.0)

  const DetectedObject({
    required this.name,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

class ObjectRecognitionResult {
  final List<DetectedObject> objects;

  // Spoken text = just the object names joined
  String get spokenText {
    if (objects.isEmpty) return 'Nothing detected';
    final names = objects.map((o) => o.name).toList();
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  const ObjectRecognitionResult({required this.objects});

  bool isSimilarTo(ObjectRecognitionResult? other) {
    if (other == null) return false;
    final a = objects.map((o) => o.name.toLowerCase()).toSet();
    final b = other.objects.map((o) => o.name.toLowerCase()).toSet();
    if (a.isEmpty || b.isEmpty) return false;
    return a.intersection(b).length / a.length > 0.6;
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ObjectRecognitionService {
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY';

  static const List<String> _models = [
    'gemini-2.5-flash-lite',
    'gemini-2.5-flash',
    'gemini-2.5-flash-preview-04-17',
  ];

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  // Ask Gemini for JSON with object names + bounding boxes.
  // ymin/xmin/ymax/xmax are 0–1000 (Gemini's native coordinate scale).
  static const String _prompt =
      'Detect all objects in this image. '
      'Respond ONLY with a valid JSON array. No markdown, no explanation, no extra text. '
      'Each element must have exactly these keys: '
      '"name" (short label, 1-3 words), '
      '"xmin" (0-1000), "ymin" (0-1000), "xmax" (0-1000), "ymax" (0-1000). '
      'Example: [{"name":"chair","xmin":120,"ymin":200,"xmax":400,"ymax":800}]. '
      'If nothing is detected, return [].';

  String? _workingModel;

  Future<ObjectRecognitionResult?> recognizeObjects(Uint8List imageBytes) async {
    if (_workingModel != null) {
      return _callModel(_workingModel!, imageBytes);
    }
    for (final model in _models) {
      print('🔄 Trying model: $model');
      try {
        final result = await _callModel(model, imageBytes);
        if (result != null) {
          _workingModel = model;
          print('✅ Working model: $model');
          return result;
        }
      } catch (e) {
        print('⚠️ $model failed: $e');
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
            {'text': _prompt},
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 512,
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
      throw Exception('Model not available: ${response.statusCode}');
    }
    if (response.statusCode != 200) {
      final err = jsonDecode(response.body);
      throw Exception(err['error']?['message'] ?? 'HTTP ${response.statusCode}');
    }

    final json = jsonDecode(response.body);
    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;

    final parts = candidates[0]?['content']?['parts'] as List?;
    if (parts == null || parts.isEmpty) return null;

    // Collect all text from parts
    final rawText = parts
        .map((p) => (p['text'] ?? '').toString())
        .where((t) => t.isNotEmpty)
        .join('')
        .trim();

    print('💬 Raw response: $rawText');

    return _parseResult(rawText);
  }

  ObjectRecognitionResult _parseResult(String rawText) {
    try {
      // Strip markdown code fences if present
      String cleaned = rawText
          .replaceAll(RegExp(r'```json\s*', caseSensitive: false), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      // Find the JSON array in the response
      final start = cleaned.indexOf('[');
      final end = cleaned.lastIndexOf(']');
      if (start == -1 || end == -1 || end <= start) {
        print('⚠️ No JSON array found in response');
        return const ObjectRecognitionResult(objects: []);
      }

      final jsonStr = cleaned.substring(start, end + 1);
      final List<dynamic> raw = jsonDecode(jsonStr);

      final objects = <DetectedObject>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        // Gemini returns 0–1000; convert to 0.0–1.0
        final xmin = _toDouble(item['xmin']) / 1000.0;
        final ymin = _toDouble(item['ymin']) / 1000.0;
        final xmax = _toDouble(item['xmax']) / 1000.0;
        final ymax = _toDouble(item['ymax']) / 1000.0;

        // Clamp & validate
        final l = xmin.clamp(0.0, 1.0);
        final t = ymin.clamp(0.0, 1.0);
        final r = xmax.clamp(0.0, 1.0);
        final b = ymax.clamp(0.0, 1.0);

        if (r <= l || b <= t) continue; // degenerate box

        objects.add(DetectedObject(
          name: name,
          left: l,
          top: t,
          width: r - l,
          height: b - t,
        ));
      }

      print('✅ Parsed ${objects.length} object(s): ${objects.map((o) => o.name).join(', ')}');
      return ObjectRecognitionResult(objects: objects);
    } catch (e) {
      print('❌ Parse error: $e');
      return const ObjectRecognitionResult(objects: []);
    }
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }
}