import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint, Uint8List;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import '../utils/image_utils.dart';
import 'language_preference_service.dart';

// ── Detected object with normalized bounding box ─────────────────────────────
class DetectedObject {
  final String name;
  final double confidence; // 0.0–1.0 confidence score
  final double left;   // x of top-left corner (0.0–1.0)
  final double top;    // y of top-left corner (0.0–1.0)
  final double width;  // box width  (0.0–1.0)
  final double height; // box height (0.0–1.0)

  const DetectedObject({
    required this.name,
    this.confidence = 1.0,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  String get displayName {
    final isHindi = LanguagePreferenceService().isHindi;
    if (!isHindi) return name;
    switch (name.toLowerCase()) {
      case 'person': return 'व्यक्ति';
      case 'bicycle': return 'साइकिल';
      case 'car': return 'कार';
      case 'motorcycle': return 'मोटरसाइकिल';
      case 'airplane': return 'हवाई जहाज';
      case 'bus': return 'बस';
      case 'train': return 'ट्रेन';
      case 'truck': return 'ट्रक';
      case 'boat': return 'नाव';
      case 'traffic light': return 'ट्रैफिक सिग्नल';
      case 'fire hydrant': return 'फायर हाइड्रेंट';
      case 'stop sign': return 'स्टॉप साइन';
      case 'parking meter': return 'पार्किंग मीटर';
      case 'bench': return 'बेंच';
      case 'bird': return 'पक्षी';
      case 'cat': return 'बिल्ली';
      case 'dog': return 'कुत्ता';
      case 'horse': return 'घोड़ा';
      case 'sheep': return 'भेड़';
      case 'cow': return 'गाय';
      case 'elephant': return 'हाथी';
      case 'bear': return 'भालू';
      case 'zebra': return 'जेब्रा';
      case 'giraffe': return 'जिराफ';
      case 'backpack': return 'बस्ता';
      case 'umbrella': return 'छाता';
      case 'handbag': return 'पर्स';
      case 'tie': return 'टाई';
      case 'suitcase': return 'सूटकेस';
      case 'frisbee': return 'फ्रिसबी';
      case 'skis': return 'स्की';
      case 'sports ball': return 'गेंद';
      case 'kite': return 'पतंग';
      case 'baseball bat': return 'बल्ला';
      case 'baseball glove': return 'दस्ताना';
      case 'skateboard': return 'स्केटबोर्ड';
      case 'surfboard': return 'सर्फबोर्ड';
      case 'tennis racket': return 'टेनिस रैकेट';
      case 'bottle': return 'बोतल';
      case 'wine glass': return 'कांच का गिलास';
      case 'cup': return 'कप';
      case 'fork': return 'कांटा';
      case 'knife': return 'चाकू';
      case 'spoon': return 'चम्मच';
      case 'bowl': return 'कटोरा';
      case 'banana': return 'केला';
      case 'apple': return 'सेब';
      case 'sandwich': return 'सैंडविच';
      case 'orange': return 'संतरा';
      case 'broccoli': return 'ब्रोकली';
      case 'carrot': return 'गाजर';
      case 'hot dog': return 'हॉट डॉग';
      case 'pizza': return 'पिज्जा';
      case 'donut': return 'डोनट';
      case 'cake': return 'केक';
      case 'chair': return 'कुर्सी';
      case 'couch': return 'सोफा';
      case 'potted plant': return 'पौधा';
      case 'bed': return 'बिस्तर';
      case 'dining table': return 'खाने की मेज';
      case 'toilet': return 'शौचालय';
      case 'tv': return 'टीवी';
      case 'laptop': return 'लैपटॉप';
      case 'mouse': return 'माउस';
      case 'remote': return 'रिमोट';
      case 'keyboard': return 'कीबोर्ड';
      case 'cell phone': return 'मोबाइल फोन';
      case 'microwave': return 'माइक्रोवेव';
      case 'oven': return 'ओवन';
      case 'toaster': return 'टोस्टर';
      case 'sink': return 'सिंक';
      case 'refrigerator': return 'फ्रिज';
      case 'book': return 'किताब';
      case 'clock': return 'घड़ी';
      case 'vase': return 'फूलदान';
      case 'scissors': return 'कैंची';
      case 'teddy bear': return 'टेडी बियर';
      case 'hair drier': return 'हेयर ड्रायर';
      case 'toothbrush': return 'टूथब्रश';
      default: return name;
    }
  }
}

class ObjectRecognitionResult {
  final List<DetectedObject> objects;
  final bool isHighPrecisionAI;

  String get spokenText {
    if (objects.isEmpty) {
      return LanguagePreferenceService().isHindi ? 'कोई वस्तु नहीं मिली' : 'Nothing detected';
    }
    final names = objects.map((o) => o.displayName).toList();
    if (names.length == 1) return names.first;
    final last = names.last;
    final leading = names.sublist(0, names.length - 1).join(', ');
    return LanguagePreferenceService().isHindi ? '$leading और $last' : '$leading and $last';
  }

  const ObjectRecognitionResult({
    required this.objects,
    this.isHighPrecisionAI = false,
  });

  bool isSimilarTo(ObjectRecognitionResult? other) {
    if (other == null) return false;
    final a = objects.map((o) => o.name.toLowerCase()).toSet();
    final b = other.objects.map((o) => o.name.toLowerCase()).toSet();
    if (a.isEmpty || b.isEmpty) return false;
    final intersection = a.intersection(b).length;
    return (intersection / a.length) > 0.6;
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ObjectRecognitionService {
  static const String _modelAsset = 'assets/models/ssd_mobilenet_v2.tflite';
  static const String _labelsAsset = 'assets/models/coco_labels.txt';
  static const int _inputSize = 300;
  static const double _confidenceThreshold = 0.55; // Heightened threshold for high precision
  static const double _nmsIoUThreshold = 0.40;       // Non-Maximum Suppression overlap cutoff

  static const String _apiKey = String.fromEnvironment(
    'GEMINI_VISION_API_KEY',
    defaultValue: String.fromEnvironment('GEMINI_API_KEY'),
  );
  static const List<String> _geminiModels = [
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final options = InterpreterOptions()..threads = 4;
      _interpreter = await Interpreter.fromAsset(_modelAsset, options: options);

      final labelsRaw = await rootBundle.loadString(_labelsAsset);
      _labels = labelsRaw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

      _isInitialized = true;
      debugPrint('[ObjRecog] Initialised on-device TFLite model');
    } catch (e) {
      debugPrint('[ObjRecog] TFLite Init failed: $e');
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }

  /// On-device high-accuracy detection pipeline with NMS and geometric filtering
  Future<ObjectRecognitionResult?> recognizeObjects(CameraImage cameraImage, int sensorOrientation) async {
    if (!_isInitialized || _interpreter == null) return null;

    try {
      // 1. Process camera image in background isolate to prevent frame lag & color distortion
      final resized = await processCameraImageIsolate(
        image: cameraImage,
        sensorOrientation: sensorOrientation,
        resizeWidth: _inputSize,
        resizeHeight: _inputSize,
      );

      final input = _buildInputTensor(resized);

      final numLocations = _interpreter!.getOutputTensor(0).shape[1];
      final outputLocations = List<List<List<double>>>.generate(1, (_) => List<List<double>>.generate(numLocations, (_) => List<double>.filled(4, 0.0)));
      final outputClasses = List<List<double>>.generate(1, (_) => List<double>.filled(numLocations, 0.0));
      final outputScores = List<List<double>>.generate(1, (_) => List<double>.filled(numLocations, 0.0));
      final outputNumDet = List<double>.filled(1, 0.0);

      final outputs = {
        0: outputLocations,
        1: outputClasses,
        2: outputScores,
        3: outputNumDet,
      };

      _interpreter!.runForMultipleInputs([input], outputs);

      final numDetections = outputNumDet[0].toInt().clamp(0, numLocations);
      final rawCandidates = <DetectedObject>[];

      for (int i = 0; i < numDetections; i++) {
        final score = outputScores[0][i];
        if (score < _confidenceThreshold) continue;

        final classIdx = outputClasses[0][i].toInt();
        if (classIdx < 0 || classIdx >= _labels.length) continue;

        final label = _labels[classIdx];
        if (label.isEmpty || label == 'n/a') continue;

        final top = outputLocations[0][i][0].clamp(0.0, 1.0);
        final left = outputLocations[0][i][1].clamp(0.0, 1.0);
        final bottom = outputLocations[0][i][2].clamp(0.0, 1.0);
        final right = outputLocations[0][i][3].clamp(0.0, 1.0);

        final width = right - left;
        final height = bottom - top;

        if (width <= 0 || height <= 0) continue;

        // Area & Aspect Ratio Geometric Noise Filtering
        final area = width * height;
        final aspectRatio = width > height ? width / height : height / width;

        // Skip tiny noise boxes unless confidence is extremely high
        if (area < 0.012 && score < 0.80) continue;
        // Skip unnatural anchor box stretch anomalies
        if (aspectRatio > 5.5) continue;

        rawCandidates.add(DetectedObject(
          name: label,
          confidence: score,
          left: left,
          top: top,
          width: width,
          height: height,
        ));
      }

      // 2. Perform Non-Maximum Suppression (NMS) to eliminate duplicate/overlapping detections
      final nmsFiltered = _applyNMS(rawCandidates, _nmsIoUThreshold);

      // Sort by area size (larger = closer/more prominent)
      nmsFiltered.sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        return areaB.compareTo(areaA);
      });

      return ObjectRecognitionResult(objects: nmsFiltered);
    } catch (e) {
      debugPrint('[ObjRecog] Detection error: $e');
      return null;
    }
  }

  /// High-Precision Cloud AI Object Detection using Gemini Vision
  /// Capable of recognizing fine details (e.g. medicine bottles, specific electronics, keys, documents)
  Future<ObjectRecognitionResult?> recognizeObjectsGemini(Uint8List jpegBytes) async {
    final isHindi = LanguagePreferenceService().isHindi;
    final prompt = isHindi
        ? 'आप एक दृष्टिबाधित व्यक्ति के लिए वस्तु पहचान सहायक हैं। '
          'इस छवि में स्पष्ट रूप से दिखाई देने वाली मुख्य वस्तुओं की सटीक पहचान करें। '
          'केवल उन्हीं वस्तुओं को सूचीबद्ध करें जो वास्तव में दिखाई दे रही हैं (उदा. "पानी की बोतल", "चश्मा", "चाबी", "लैपटॉप", "सूटकेस")। '
          'अनुमान न लगाएं। उत्तर केवल एक JSON array of strings के रूप में दें, जैसे: ["वस्तु 1", "वस्तु 2"]।'
        : 'You are an accurate object recognition assistant for a visually impaired person. '
          'Identify distinct visible objects in this photo with high accuracy. '
          'List only clearly visible items with exact names (e.g. "Water bottle", "Eyeglasses", "Car keys", "Laptop", "Backpack", "Coffee cup"). '
          'Do not guess objects that are ambiguous. Return strictly a JSON array of strings, e.g.: ["Object 1", "Object 2"].';

    final List<Map<String, dynamic>> parts = [
      {
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(jpegBytes),
        }
      },
      {'text': prompt}
    ];

    final body = jsonEncode({
      'contents': [
        {'parts': parts}
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 150,
      }
    });

    for (final model in _geminiModels) {
      try {
        final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$_apiKey');
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: body,
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          final candidateText = json['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '';

          final List<String> parsedNames = _parseGeminiJsonList(candidateText);
          final objects = parsedNames.map((name) => DetectedObject(
            name: name,
            confidence: 0.95,
            left: 0.1,
            top: 0.1,
            width: 0.8,
            height: 0.8,
          )).toList();

          return ObjectRecognitionResult(objects: objects, isHighPrecisionAI: true);
        }
      } catch (e) {
        debugPrint('[ObjRecog] Gemini API error ($model): $e');
      }
    }

    return null;
  }

  /// Parses Gemini's raw output string into a list of object names
  List<String> _parseGeminiJsonList(String text) {
    try {
      final clean = text.replaceAll('```json', '').replaceAll('```', '').trim();
      final List<dynamic> jsonList = jsonDecode(clean);
      return jsonList.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      // Fallback: line-by-line or comma split
      final lines = text.split('\n')
          .map((l) => l.replaceAll(RegExp(r'^[\s\*\-\d\.\"]+'), '').replaceAll('"', '').trim())
          .where((l) => l.isNotEmpty && l.length < 40)
          .toList();
      return lines.take(6).toList();
    }
  }

  /// Non-Maximum Suppression (NMS) logic
  List<DetectedObject> _applyNMS(List<DetectedObject> boxes, double iouThreshold) {
    if (boxes.isEmpty) return [];

    // Sort by confidence descending
    final sorted = List<DetectedObject>.from(boxes)..sort((a, b) => b.confidence.compareTo(a.confidence));
    final selected = <DetectedObject>[];

    for (final box in sorted) {
      bool keep = true;
      for (final prev in selected) {
        if (_calculateIoU(box, prev) > iouThreshold) {
          keep = false;
          break;
        }
      }
      if (keep) {
        selected.add(box);
      }
    }

    return selected;
  }

  /// Calculates Intersection over Union (IoU) between two bounding boxes
  double _calculateIoU(DetectedObject a, DetectedObject b) {
    final double x1 = a.left > b.left ? a.left : b.left;
    final double y1 = a.top > b.top ? a.top : b.top;
    final double x2 = (a.left + a.width) < (b.left + b.width) ? (a.left + a.width) : (b.left + b.width);
    final double y2 = (a.top + a.height) < (b.top + b.height) ? (a.top + a.height) : (b.top + b.height);

    final double interW = x2 - x1;
    final double interH = y2 - y1;

    if (interW <= 0 || interH <= 0) return 0.0;

    final double interArea = interW * interH;
    final double areaA = a.width * a.height;
    final double areaB = b.width * b.height;

    final double unionArea = areaA + areaB - interArea;
    return unionArea <= 0 ? 0.0 : interArea / unionArea;
  }

  List<List<List<List<int>>>> _buildInputTensor(img.Image resized) {
    return List<List<List<List<int>>>>.generate(
      1,
      (_) => List<List<List<int>>>.generate(
        _inputSize,
        (y) => List<List<int>>.generate(_inputSize, (x) {
          final pixel = resized.getPixel(x, y);
          return <int>[pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        }),
      ),
    );
  }
}