// lib/services/depth_estimation_service.dart
//
// Real-time depth estimation for navigation obstacle proximity.
//
// Uses MiDaS v2.1 Small TFLite model for per-pixel depth maps, with a
// bounding-box-area heuristic as fallback.
//
// Distances are expressed in **steps** (1 step ≈ 0.6 m).
// Safe walking direction is computed from depth-map column analysis.

import 'dart:ui' show Rect;
import 'dart:math' show min, pi;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../utils/image_utils.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

/// 1 step ≈ 0.6 metres (average stride length)
const double kMetersPerStep = 0.6;

// ─── Proximity zones ─────────────────────────────────────────────────────────

/// Coarse proximity estimate derived from depth analysis.
enum ProximityZone {
  /// Object fills a large portion of the frame — collision imminent.
  veryClose, // ≈ 0–2 steps (0–1.2 m)

  /// Object is nearby and may require immediate action.
  close, // ≈ 2–4 steps (1.2–2.5 m)

  /// Object is visible but not an immediate threat.
  near, // ≈ 4–8 steps (2.5–5 m)

  /// Object is far away — informational only.
  far, // > 8 steps (> 5 m)
}

// ─── Depth result ────────────────────────────────────────────────────────────

/// Result of depth estimation for one detected object.
class DepthEstimate {
  /// Estimated distance in metres (approximate).
  final double distanceMeters;

  /// Estimated distance in steps (1 step = 0.6 m).
  double get distanceSteps => distanceMeters / kMetersPerStep;

  /// Coarse proximity zone.
  final ProximityZone zone;

  /// Raw area fraction of the bounding box (0.0–1.0).
  final double areaFraction;

  /// Whether this estimate came from the depth model (true) or heuristic (false).
  final bool fromDepthModel;

  const DepthEstimate({
    required this.distanceMeters,
    required this.zone,
    required this.areaFraction,
    this.fromDepthModel = false,
  });

  /// Human-readable distance label in steps for overlays.
  String get label {
    final steps = distanceSteps;
    if (steps < 1.0) return '< 1 step';
    if (steps < 2.0) return '~${steps.toStringAsFixed(0)} step';
    return '~${steps.round()} steps';
  }

  @override
  String toString() => 'DepthEstimate($label, zone=$zone, model=$fromDepthModel)';
}

// ─── Safe direction result ───────────────────────────────────────────────────

/// The safest walking direction derived from depth map analysis.
class SafeDirection {
  /// Angle in radians from 12 o'clock (0 = straight ahead, π/2 = 3 o'clock).
  final double angleRadians;

  /// Clock position (1–12).
  final int clockPosition;

  /// Average depth value in the safe column (higher = farther = safer).
  final double safetyScore;

  /// Human-readable clock position string.
  String get clockLabel => "$clockPosition o'clock";

  const SafeDirection({
    required this.angleRadians,
    required this.clockPosition,
    required this.safetyScore,
  });

  /// Default: straight ahead (12 o'clock).
  static const SafeDirection straightAhead = SafeDirection(
    angleRadians: 0.0,
    clockPosition: 12,
    safetyScore: 1.0,
  );
}

// ─── Per-object reference sizes ──────────────────────────────────────────────

const Map<String, double> _referenceWidths = {
  'person': 0.50,
  'bicycle': 0.60,
  'car': 1.80,
  'motorcycle': 0.80,
  'bus': 2.55,
  'truck': 2.50,
  'train': 3.00,
  'dog': 0.45,
  'cat': 0.30,
  'chair': 0.50,
  'bench': 1.50,
  'fire hydrant': 0.30,
  'stop sign': 0.60,
  'potted plant': 0.40,
  'suitcase': 0.45,
  'backpack': 0.35,
  'umbrella': 1.00,
  'cow': 1.50,
  'horse': 1.40,
  'elephant': 3.00,
  'couch': 2.00,
  'bed': 1.60,
  'dining table': 1.20,
  'traffic light': 0.30,
};

// ─── Depth map column analysis config ────────────────────────────────────────

/// Number of horizontal columns to divide the depth map into for safe-direction
/// analysis. More columns = finer angular resolution.
const int _kDepthColumns = 12;

/// Only analyse the lower portion of the depth map (ground plane).
const double _kDepthAnalysisTopFraction = 0.35; // ignore top 35% (sky/buildings)

// ─── Clock position ↔ column mapping ─────────────────────────────────────────

/// Maps a column index (0 = far left, _kDepthColumns-1 = far right) to
/// a clock position.
///
/// Camera FoV is roughly 60°, so the visual range maps to roughly
/// 9 o'clock (left edge) → 12 o'clock (centre) → 3 o'clock (right edge).
int _columnToClockPosition(int column, int totalColumns) {
  // Map column 0..totalColumns-1 to the clock range 9..3 (wrapping through 12)
  // 9, 10, 11, 12, 1, 2, 3
  final clockPositions = [9, 10, 10, 11, 11, 12, 12, 1, 1, 2, 2, 3];
  if (totalColumns != clockPositions.length) {
    // Linear interpolation fallback
    final fraction = column / (totalColumns - 1); // 0.0 (left) to 1.0 (right)
    // 9 o'clock = 270°, 3 o'clock = 90°; linear through 12 (0°/360°)
    if (fraction <= 0.5) {
      // Left half: 9 → 12
      final t = fraction * 2; // 0.0 → 1.0
      final pos = 9 + (t * 3).round(); // 9 → 12
      return pos > 12 ? pos - 12 : pos;
    } else {
      // Right half: 12 → 3
      final t = (fraction - 0.5) * 2; // 0.0 → 1.0
      return (12 + (t * 3).round()) > 12
          ? (t * 3).round()
          : 12 + (t * 3).round();
    }
  }
  return clockPositions[column.clamp(0, clockPositions.length - 1)];
}

/// Convert clock position to angle in radians (0 = 12 o'clock, clockwise).
double _clockToRadians(int clockPos) {
  // 12 o'clock = 0, 3 = π/2, 6 = π, 9 = 3π/2
  return ((clockPos % 12) / 12.0) * 2.0 * pi;
}

// ─── Service ─────────────────────────────────────────────────────────────────

class DepthEstimationService {
  // ── Area-fraction thresholds for zone classification ──────────────────────
  static const double _veryCloseThreshold = 0.15;
  static const double _closeThreshold = 0.07;
  static const double _nearThreshold = 0.025;

  // ── Heuristic focal length ────────────────────────────────────────────────
  static const double _normalisedFocalLength = 0.87;

  // ── MiDaS model ──────────────────────────────────────────────────────────
  static const String _midasModelAsset = 'assets/models/midas_v2_small.tflite';
  static const int _midasInputSize = 256;

  Interpreter? _midasInterpreter;
  bool _midasReady = false;

  /// The most recent depth map (normalised 0.0–1.0), flattened row-major.
  /// Shape: [_midasInputSize × _midasInputSize].
  List<double>? _lastDepthMap;
  int _depthMapWidth = _midasInputSize;
  int _depthMapHeight = _midasInputSize;

  /// The most recent safe direction computed from the depth map.
  SafeDirection _lastSafeDirection = SafeDirection.straightAhead;

  bool get isMidasReady => _midasReady;
  SafeDirection get lastSafeDirection => _lastSafeDirection;
  List<double>? get lastDepthMap => _lastDepthMap;

  // ── MiDaS normalisation constants (ImageNet) ──────────────────────────────
  static const List<double> _mean = [0.485, 0.456, 0.406];
  static const List<double> _std = [0.229, 0.224, 0.225];

  // ═══════════════════════════════════════════════════════════════════════════
  //  Initialisation
  // ═══════════════════════════════════════════════════════════════════════════

  /// Try to load MiDaS TFLite model. Non-fatal — falls back to heuristic.
  Future<void> initMidas() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _midasInterpreter =
          await Interpreter.fromAsset(_midasModelAsset, options: options);
      _midasReady = true;
      debugPrint('[DepthEst] MiDaS model loaded successfully');
      debugPrint('[DepthEst] Input: ${_midasInterpreter!.getInputTensors()}');
      debugPrint('[DepthEst] Output: ${_midasInterpreter!.getOutputTensors()}');
    } catch (e) {
      debugPrint('[DepthEst] MiDaS model not available, using heuristic: $e');
      _midasReady = false;
    }
  }

  void dispose() {
    _midasInterpreter?.close();
    _midasInterpreter = null;
    _midasReady = false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Depth Map Inference
  // ═══════════════════════════════════════════════════════════════════════════

  /// Run MiDaS depth estimation on a camera frame.
  /// Returns the depth map as a flat list of normalised values (0.0–1.0),
  /// or null if the model is not available.
  Future<List<double>?> estimateDepthMap(CameraImage cameraImage, int sensorOrientation) async {
    if (!_midasReady || _midasInterpreter == null) return null;

    try {
      // 1. Convert camera image to RGB and resize to 256×256
      final resized = await processCameraImageIsolate(
        image: cameraImage,
        sensorOrientation: sensorOrientation,
        resizeWidth: _midasInputSize,
        resizeHeight: _midasInputSize,
      );

      // 2. Build normalised float32 input tensor [1, 256, 256, 3]
      final input = _buildMidasInput(resized);

      // 3. Allocate output [1, 256, 256, 1]
      final output = List<List<List<List<double>>>>.generate(
        1,
        (_) => List<List<List<double>>>.generate(
          _midasInputSize,
          (_) => List<List<double>>.generate(
            _midasInputSize,
            (_) => List<double>.filled(1, 0.0),
          ),
        ),
      );

      // 4. Run inference
      _midasInterpreter!.run(input, output);

      // 5. Flatten and normalise the depth map
      final depthMap = <double>[];
      double minVal = double.infinity;
      double maxVal = double.negativeInfinity;

      for (int y = 0; y < _midasInputSize; y++) {
        for (int x = 0; x < _midasInputSize; x++) {
          final val = output[0][y][x][0];
          depthMap.add(val);
          if (val < minVal) minVal = val;
          if (val > maxVal) maxVal = val;
        }
      }

      // Normalise to 0.0–1.0
      final range = maxVal - minVal;
      if (range > 0.001) {
        for (int i = 0; i < depthMap.length; i++) {
          depthMap[i] = (depthMap[i] - minVal) / range;
        }
      }

      _lastDepthMap = depthMap;
      _depthMapWidth = _midasInputSize;
      _depthMapHeight = _midasInputSize;

      // 6. Compute safe direction from depth map
      _lastSafeDirection = _computeSafeDirection(depthMap);

      return depthMap;
    } catch (e) {
      debugPrint('[DepthEst] MiDaS inference error: $e');
      return null;
    }
  }

  /// Build normalised float32 input for MiDaS [1, 256, 256, 3].
  List<List<List<List<double>>>> _buildMidasInput(img.Image resized) {
    return List<List<List<List<double>>>>.generate(
      1,
      (_) => List<List<List<double>>>.generate(
        _midasInputSize,
        (y) => List<List<double>>.generate(_midasInputSize, (x) {
          final pixel = resized.getPixel(x, y);
          // Normalise to [0, 1] then apply ImageNet normalisation
          final r = ((pixel.r.toDouble() / 255.0) - _mean[0]) / _std[0];
          final g = ((pixel.g.toDouble() / 255.0) - _mean[1]) / _std[1];
          final b = ((pixel.b.toDouble() / 255.0) - _mean[2]) / _std[2];
          return <double>[r, g, b];
        }),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Safe Direction from Depth Map
  // ═══════════════════════════════════════════════════════════════════════════

  /// Analyses the depth map to find the safest walking direction.
  /// Divides the lower portion of the frame into columns and picks the
  /// column with the highest average depth (= farthest = most walkable).
  SafeDirection _computeSafeDirection(List<double> depthMap) {
    final colWidth = _depthMapWidth ~/ _kDepthColumns;
    final startRow = (_depthMapHeight * _kDepthAnalysisTopFraction).round();

    final colAverages = List<double>.filled(_kDepthColumns, 0.0);
    final colCounts = List<int>.filled(_kDepthColumns, 0);

    for (int y = startRow; y < _depthMapHeight; y++) {
      for (int col = 0; col < _kDepthColumns; col++) {
        final xStart = col * colWidth;
        final xEnd = min(xStart + colWidth, _depthMapWidth);

        for (int x = xStart; x < xEnd; x++) {
          final idx = y * _depthMapWidth + x;
          if (idx < depthMap.length) {
            // MiDaS outputs *inverse* depth (closer = higher value)
            // So for "safe" we want LOWER values (= farther away)
            // We invert: higher = safer
            colAverages[col] += (1.0 - depthMap[idx]);
            colCounts[col]++;
          }
        }
      }
    }

    // Compute averages
    int bestCol = _kDepthColumns ~/ 2; // default: center
    double bestAvg = 0.0;

    for (int col = 0; col < _kDepthColumns; col++) {
      if (colCounts[col] > 0) {
        colAverages[col] /= colCounts[col];
      }
      if (colAverages[col] > bestAvg) {
        bestAvg = colAverages[col];
        bestCol = col;
      }
    }

    final clockPos = _columnToClockPosition(bestCol, _kDepthColumns);
    final angle = _clockToRadians(clockPos);

    return SafeDirection(
      angleRadians: angle,
      clockPosition: clockPos,
      safetyScore: bestAvg,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  Per-object Depth Estimation (with depth map enhancement)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Estimate depth for a single bounding box.
  ///
  /// If a depth map is available, samples the depth within the bounding box
  /// for a more accurate estimate. Otherwise, uses the heuristic.
  DepthEstimate estimate(Rect box, String label) {
    final areaFraction = box.width * box.height;

    double distanceMeters;
    bool fromModel = false;

    // Try depth map sampling first
    if (_lastDepthMap != null) {
      final mapDist = _sampleDepthMapForBox(box);
      if (mapDist != null) {
        distanceMeters = mapDist;
        fromModel = true;
      } else {
        distanceMeters = _heuristicDistance(box, label, areaFraction);
      }
    } else {
      distanceMeters = _heuristicDistance(box, label, areaFraction);
    }

    // Clamp to sensible range
    distanceMeters = distanceMeters.clamp(0.2, 30.0);

    // Classify proximity zone
    final zone = _classifyZone(areaFraction, distanceMeters);

    return DepthEstimate(
      distanceMeters: distanceMeters,
      zone: zone,
      areaFraction: areaFraction,
      fromDepthModel: fromModel,
    );
  }

  /// Batch-estimate depth for multiple detections.
  List<DepthEstimate> estimateAll(List<Rect> boxes, List<String> labels) {
    assert(boxes.length == labels.length);
    return List.generate(boxes.length, (i) => estimate(boxes[i], labels[i]));
  }

  // ── Depth map sampling ────────────────────────────────────────────────────

  /// Sample the depth map within a bounding box to get median depth,
  /// then convert from MiDaS inverse depth to approximate metres.
  double? _sampleDepthMapForBox(Rect box) {
    if (_lastDepthMap == null) return null;

    // Map normalised bbox coords to depth map pixel coords
    final x1 = (box.left * _depthMapWidth).round().clamp(0, _depthMapWidth - 1);
    final y1 = (box.top * _depthMapHeight).round().clamp(0, _depthMapHeight - 1);
    final x2 = (box.right * _depthMapWidth).round().clamp(0, _depthMapWidth - 1);
    final y2 = (box.bottom * _depthMapHeight).round().clamp(0, _depthMapHeight - 1);

    if (x2 <= x1 || y2 <= y1) return null;

    // Sample the centre 50% of the bbox to avoid edge noise
    final cx1 = x1 + ((x2 - x1) * 0.25).round();
    final cx2 = x2 - ((x2 - x1) * 0.25).round();
    final cy1 = y1 + ((y2 - y1) * 0.25).round();
    final cy2 = y2 - ((y2 - y1) * 0.25).round();

    final samples = <double>[];
    for (int y = cy1; y <= cy2; y++) {
      for (int x = cx1; x <= cx2; x++) {
        final idx = y * _depthMapWidth + x;
        if (idx < _lastDepthMap!.length) {
          samples.add(_lastDepthMap![idx]);
        }
      }
    }

    if (samples.isEmpty) return null;

    // MiDaS: normalised inverse depth (higher = closer)
    // Median for robustness
    samples.sort();
    final median = samples[samples.length ~/ 2];

    // Convert inverse depth to approximate metres:
    // d_metres ≈ scale / depth_value
    // Calibrated so median ≈ 0.5 maps to ~2m
    if (median < 0.01) return 20.0; // very far
    final distMeters = 1.2 / median;
    return distMeters.clamp(0.3, 25.0);
  }

  // ── Heuristic (fallback) ──────────────────────────────────────────────────

  double _heuristicDistance(Rect box, String label, double areaFraction) {
    final refWidth = _referenceWidths[label.toLowerCase()];
    if (refWidth != null && box.width > 0.01) {
      return (refWidth * _normalisedFocalLength) / box.width;
    }
    return _areaToDistance(areaFraction);
  }

  double _areaToDistance(double area) {
    if (area <= 0.001) return 15.0;
    return 0.20 / (area.clamp(0.001, 1.0));
  }

  ProximityZone _classifyZone(double areaFraction, double distance) {
    if (areaFraction >= _veryCloseThreshold) return ProximityZone.veryClose;
    if (areaFraction >= _closeThreshold) return ProximityZone.close;
    if (areaFraction >= _nearThreshold) return ProximityZone.near;

    // Step-based classification
    final steps = distance / kMetersPerStep;
    if (steps < 2) return ProximityZone.veryClose;
    if (steps < 4) return ProximityZone.close;
    if (steps < 8) return ProximityZone.near;
    return ProximityZone.far;
  }
}
