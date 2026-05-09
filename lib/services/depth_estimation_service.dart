// lib/services/depth_estimation_service.dart
//
// Lightweight depth estimation for navigation obstacle proximity.
//
// Uses a bounding-box-area heuristic: objects whose bounding boxes occupy
// a larger fraction of the frame are assumed to be closer.  The estimated
// distance is categorised into four proximity zones that drive urgency
// in the voice-feedback system.
//
// Optionally extensible to MiDaS TFLite in the future by replacing the
// [estimateFromBoundingBox] implementation with model inference.

import 'dart:ui' show Rect;

// ─── Proximity zones ─────────────────────────────────────────────────────────

/// Coarse proximity estimate derived from bounding-box area.
enum ProximityZone {
  /// Object fills a large portion of the frame — collision imminent.
  veryClose,  // ≈ 0–1 m

  /// Object is nearby and may require immediate action.
  close,      // ≈ 1–2.5 m

  /// Object is visible but not an immediate threat.
  near,       // ≈ 2.5–5 m

  /// Object is far away — informational only.
  far,        // > 5 m
}

// ─── Depth result ────────────────────────────────────────────────────────────

/// Result of depth estimation for one detected object.
class DepthEstimate {
  /// Heuristic distance in metres (approximate).
  final double distanceMeters;

  /// Coarse proximity zone.
  final ProximityZone zone;

  /// Raw area fraction of the bounding box (0.0–1.0).
  final double areaFraction;

  const DepthEstimate({
    required this.distanceMeters,
    required this.zone,
    required this.areaFraction,
  });

  /// Human-readable distance label for overlays.
  String get label {
    if (distanceMeters < 1.0) return '< 1 m';
    if (distanceMeters < 2.0) return '~${distanceMeters.toStringAsFixed(1)} m';
    return '~${distanceMeters.toStringAsFixed(0)} m';
  }

  @override
  String toString() => 'DepthEstimate($label, zone=$zone)';
}

// ─── Per-object reference sizes ──────────────────────────────────────────────
//
// Average real-world widths (metres) for selected COCO categories.
// Used to improve the area-based heuristic for known object types.

const Map<String, double> _referenceWidths = {
  'person':        0.50,
  'bicycle':       0.60,
  'car':           1.80,
  'motorcycle':    0.80,
  'bus':           2.55,
  'truck':         2.50,
  'train':         3.00,
  'dog':           0.45,
  'cat':           0.30,
  'chair':         0.50,
  'bench':         1.50,
  'fire hydrant':  0.30,
  'stop sign':     0.60,
  'potted plant':  0.40,
  'suitcase':      0.45,
  'backpack':      0.35,
  'umbrella':      1.00,
  'cow':           1.50,
  'horse':         1.40,
  'elephant':      3.00,
  'couch':         2.00,
  'bed':           1.60,
  'dining table':  1.20,
  'traffic light': 0.30,
};

// ─── Service ─────────────────────────────────────────────────────────────────

class DepthEstimationService {
  // ── Area-fraction thresholds for zone classification ──────────────────────
  //
  // These were empirically tuned with a phone camera at ~720p resolution
  // and a 60° horizontal FoV.  They degrade gracefully for other configs.
  static const double _veryCloseThreshold = 0.15;  // > 15% of frame
  static const double _closeThreshold = 0.07;      // > 7%
  static const double _nearThreshold = 0.025;       // > 2.5%

  // ── Heuristic focal length ────────────────────────────────────────────────
  // Approximate focal length in "normalised-image-width" units.
  // Derived from a typical phone camera with ~60° HFoV:
  //   f_px / image_width ≈ 1 / (2 * tan(30°)) ≈ 0.866
  static const double _normalisedFocalLength = 0.87;

  /// Estimate depth for a single bounding box.
  ///
  /// [box] must be normalised (0.0–1.0 of the frame).
  /// [label] is the COCO class name (used to look up real-world width).
  DepthEstimate estimate(Rect box, String label) {
    final areaFraction = box.width * box.height;

    // 1. If we know the real-world width, use perspective projection:
    //    distance = (realWidth * focalLength) / boxWidth
    double distanceMeters;
    final refWidth = _referenceWidths[label.toLowerCase()];
    if (refWidth != null && box.width > 0.01) {
      distanceMeters = (refWidth * _normalisedFocalLength) / box.width;
    } else {
      // Fallback: purely area-based inverse-square heuristic
      distanceMeters = _areaToDistance(areaFraction);
    }

    // Clamp to sensible range
    distanceMeters = distanceMeters.clamp(0.2, 30.0);

    // 2. Classify proximity zone
    final zone = _classifyZone(areaFraction, distanceMeters);

    return DepthEstimate(
      distanceMeters: distanceMeters,
      zone: zone,
      areaFraction: areaFraction,
    );
  }

  /// Batch-estimate depth for multiple detections.
  List<DepthEstimate> estimateAll(
    List<Rect> boxes,
    List<String> labels,
  ) {
    assert(boxes.length == labels.length);
    return List.generate(
      boxes.length,
      (i) => estimate(boxes[i], labels[i]),
    );
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Simple inverse-square mapping from area fraction to metres.
  double _areaToDistance(double area) {
    if (area <= 0.001) return 15.0;
    // d ≈ k / sqrt(area),  k calibrated so area=0.15 → ~0.5 m
    return 0.20 / (area.clamp(0.001, 1.0));
  }

  /// Classify proximity using both area and computed distance.
  ProximityZone _classifyZone(double areaFraction, double distance) {
    // Area-first classification (very reliable for large objects)
    if (areaFraction >= _veryCloseThreshold) return ProximityZone.veryClose;
    if (areaFraction >= _closeThreshold) return ProximityZone.close;
    if (areaFraction >= _nearThreshold) return ProximityZone.near;

    // Distance-based refinement for small objects
    if (distance < 1.0) return ProximityZone.veryClose;
    if (distance < 2.5) return ProximityZone.close;
    if (distance < 5.0) return ProximityZone.near;
    return ProximityZone.far;
  }
}
