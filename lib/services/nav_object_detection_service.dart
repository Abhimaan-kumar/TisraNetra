// lib/services/nav_object_detection_service.dart
//
// On-device object detection using SSD MobileNet v2 (COCO, quantised).
// Provides bounding boxes with danger-level classification and depth
// estimation for navigation.
//
// Input : CameraImage (YUV420)
// Output: List<NavDetectedObject> with normalised bboxes + danger + depth

import 'dart:ui' show Rect;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'depth_estimation_service.dart';
import '../utils/image_utils.dart';
import '../services/language_preference_service.dart';

// ─── Danger level for navigation alerts ──────────────────────────────────────

enum DangerLevel {
  /// Immediate collision risk — vehicles, fast-moving objects
  critical,

  /// Nearby obstacle that may block path
  warning,

  /// General scene info — not an immediate concern
  info,
}

// ─── Detected object data class ──────────────────────────────────────────────

class NavDetectedObject {
  final String label;
  final double confidence;

  /// Normalised bounding box (0.0–1.0 of image dimensions)
  final Rect boundingBox;

  /// Classified danger level for navigation alert priority
  final DangerLevel dangerLevel;

  /// Estimated distance in metres (from depth estimation service)
  final double estimatedDistance;

  /// Proximity zone for urgency classification
  final ProximityZone proximityZone;

  /// Human-readable distance label (e.g. "~2 m")
  final String distanceLabel;

  /// Horizontal centre of the bounding box (0.0 = left edge, 1.0 = right edge)
  double get centerX => boundingBox.left + boundingBox.width / 2;

  /// Vertical centre of the bounding box (0.0 = top, 1.0 = bottom)
  double get centerY => boundingBox.top + boundingBox.height / 2;

  /// Approximate area fraction of the frame (larger = closer)
  double get areaFraction => boundingBox.width * boundingBox.height;

  /// Translated label for voice/UI in Hindi if preferred.
  String get labelLabel {
    final isHindi = LanguagePreferenceService().isHindi;
    if (!isHindi) return label;
    switch (label.toLowerCase()) {
      case 'person': return 'व्यक्ति';
      case 'bicycle': return 'साइकिल';
      case 'car': return 'कार';
      case 'motorcycle': return 'मोटरसाइकिल';
      case 'bus': return 'बस';
      case 'train': return 'ट्रेन';
      case 'truck': return 'ट्रक';
      case 'traffic light': return 'यातायात बत्ती';
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
      case 'backpack': return 'बस्ता';
      case 'umbrella': return 'छाता';
      case 'handbag': return 'हाथ का थैला';
      case 'suitcase': return 'सूटकेस';
      case 'bottle': return 'बोतल';
      case 'cup': return 'कप';
      case 'chair': return 'कुर्सी';
      case 'couch': return 'सोफा';
      case 'potted plant': return 'गमला';
      case 'bed': return 'बिस्तर';
      case 'dining table': return 'खाने की मेज';
      case 'toilet': return 'शौचालय';
      case 'tv': return 'टीवी';
      case 'laptop': return 'लैपटॉप';
      case 'cell phone': return 'मोबाइल';
      case 'sink': return 'सिंक';
      case 'refrigerator': return 'फ्रिज';
      case 'book': return 'किताब';
      case 'clock': return 'घड़ी';
      default: return label;
    }
  }

  const NavDetectedObject({
    required this.label,
    required this.confidence,
    required this.boundingBox,
    required this.dangerLevel,
    required this.estimatedDistance,
    required this.proximityZone,
    required this.distanceLabel,
  });

  @override
  String toString() =>
      'NavDetectedObject($label, ${(confidence * 100).toStringAsFixed(0)}%, '
      'danger=$dangerLevel, dist=$distanceLabel, '
      'cx=${centerX.toStringAsFixed(2)})';
}

// ─── Danger classification tables ────────────────────────────────────────────

/// Objects that pose immediate collision risk
const Set<String> _criticalLabels = {
  'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'train', 'boat', 'person',
};

/// Objects that block the walking path
const Set<String> _warningLabels = {
  'fire hydrant', 'stop sign', 'parking meter', 'bench',
  'chair', 'potted plant', 'suitcase', 'backpack',
  'umbrella', 'handbag', 'traffic light', 'skateboard',
  'dog', 'cat', 'cow', 'horse', 'sheep', 'bird', 'bear', 'elephant',
};

// Everything else → DangerLevel.info

// ─── Service ─────────────────────────────────────────────────────────────────

class NavObjectDetectionService {
  static const String _modelAsset = 'assets/models/ssd_mobilenet_v2.tflite';
  static const String _labelsAsset = 'assets/models/coco_labels.txt';
  static const int _inputSize = 300;
  static const double _confidenceThreshold = 0.40;
  static const int _maxDetections = 10;

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isInitialized = false;

  /// Depth estimation engine (MiDaS model + bounding-box heuristic fallback)
  final DepthEstimationService _depthService = DepthEstimationService();

  /// Expose depth service for external depth map access (safe direction, etc.)
  DepthEstimationService get depthService => _depthService;

  bool get isInitialized => _isInitialized;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      // Load the TFLite model with XNNPack delegate for speed
      final options = InterpreterOptions()..threads = 4;
      _interpreter = await Interpreter.fromAsset(_modelAsset, options: options);

      // Load labels
      final labelsRaw = await rootBundle.loadString(_labelsAsset);
      _labels = labelsRaw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      _isInitialized = true;
      debugPrint('[NavObjDet] Initialised — ${_labels.length} labels loaded');
      debugPrint('[NavObjDet] Input: ${_interpreter!.getInputTensors()}');
      debugPrint('[NavObjDet] Output: ${_interpreter!.getOutputTensors()}');

      // Init MiDaS depth model (non-fatal — falls back to heuristic)
      await _depthService.initMidas();
    } catch (e) {
      debugPrint('[NavObjDet] Init failed: $e');
      rethrow;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _depthService.dispose();
    _isInitialized = false;
  }

  // ── Detection pipeline ────────────────────────────────────────────────────

  /// Run detection on a camera frame. Returns sorted by danger level then
  /// proximity (closer objects first).
  Future<List<NavDetectedObject>> detect(CameraImage cameraImage, int sensorOrientation) async {
    if (!_isInitialized || _interpreter == null) return [];

    try {
      // 1-3. Convert YUV420 → RGB, rotate, and resize to 300x300 in a background isolate
      final resized = await processCameraImageIsolate(
        image: cameraImage,
        sensorOrientation: sensorOrientation,
        resizeWidth: _inputSize,
        resizeHeight: _inputSize,
      );

      // 4. Build input tensor [1, 300, 300, 3] as uint8
      final input = _buildInputTensor(resized);

      // 5. Allocate output tensors (SSD MobileNet v2 has 4 outputs)
      //    [0] = locations [1, 10, 4]   — bounding boxes
      //    [1] = classes   [1, 10]      — class indices
      //    [2] = scores    [1, 10]      — confidence scores
      //    [3] = numDet    [1]          — number of detections
      final numLocations = _interpreter!.getOutputTensor(0).shape[1];

      final outputLocations = List<List<List<double>>>.generate(
        1,
        (_) => List<List<double>>.generate(numLocations, (_) => List<double>.filled(4, 0.0)),
      );
      final outputClasses = List<List<double>>.generate(
        1,
        (_) => List<double>.filled(numLocations, 0.0),
      );
      final outputScores = List<List<double>>.generate(
        1,
        (_) => List<double>.filled(numLocations, 0.0),
      );
      final outputNumDet = List<double>.filled(1, 0.0);

      final outputs = {
        0: outputLocations,
        1: outputClasses,
        2: outputScores,
        3: outputNumDet,
      };

      // 6. Run inference
      _interpreter!.runForMultipleInputs([input], outputs);

      // 7. Parse results with depth estimation
      final numDetections = outputNumDet[0].toInt().clamp(0, numLocations);
      final detections = <NavDetectedObject>[];

      for (int i = 0; i < numDetections; i++) {
        final score = outputScores[0][i];
        if (score < _confidenceThreshold) continue;

        final classIdx = outputClasses[0][i].toInt();
        if (classIdx < 0 || classIdx >= _labels.length) continue;

        final label = _labels[classIdx];
        if (label.isEmpty || label == 'n/a') continue;

        // SSD outputs: [top, left, bottom, right] normalised to 0-1
        final top = outputLocations[0][i][0].clamp(0.0, 1.0);
        final left = outputLocations[0][i][1].clamp(0.0, 1.0);
        final bottom = outputLocations[0][i][2].clamp(0.0, 1.0);
        final right = outputLocations[0][i][3].clamp(0.0, 1.0);

        if (right <= left || bottom <= top) continue;

        final bbox = Rect.fromLTRB(left, top, right, bottom);
        final dangerLevel = _classifyDanger(label);

        // Depth estimation from bounding box
        final depth = _depthService.estimate(bbox, label);

        detections.add(NavDetectedObject(
          label: label,
          confidence: score,
          boundingBox: bbox,
          dangerLevel: dangerLevel,
          estimatedDistance: depth.distanceMeters,
          proximityZone: depth.zone,
          distanceLabel: depth.label,
        ));
      }

      // Sort: critical first, then by proximity (closer = higher priority)
      detections.sort((a, b) {
        final dangerCmp = a.dangerLevel.index.compareTo(b.dangerLevel.index);
        if (dangerCmp != 0) return dangerCmp;
        return a.estimatedDistance.compareTo(b.estimatedDistance); // closer first
      });

      return detections;
    } catch (e) {
      debugPrint('[NavObjDet] Detection error: $e');
      return [];
    }
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

  // ── Danger classification ─────────────────────────────────────────────────

  DangerLevel _classifyDanger(String label) {
    final l = label.toLowerCase();
    if (_criticalLabels.contains(l)) return DangerLevel.critical;
    if (_warningLabels.contains(l)) return DangerLevel.warning;
    return DangerLevel.info;
  }
}
