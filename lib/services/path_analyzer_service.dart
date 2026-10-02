// lib/services/path_analyzer_service.dart
//
// Spatial analysis of detected objects for walking navigation.
// Divides the camera frame into 3 vertical zones (left / centre / right),
// derives approximate walkable-path boundary lines, estimates urgency from
// depth, and produces directional guidance using **clock-position** directions
// and **step-based** distances.

import 'dart:math' show min, max;
import 'depth_estimation_service.dart';
import 'nav_object_detection_service.dart';

// ─── Zone classification ─────────────────────────────────────────────────────

enum Zone { left, center, right }

// ─── Voice urgency level ─────────────────────────────────────────────────────

/// Controls TTS speech rate, pitch, and repetition.
enum VoiceUrgency {
  /// Collision imminent → fast speech, double repeat
  critical,

  /// Close obstacle → slightly fast speech, single announce
  high,

  /// Moderate obstacle → normal speech
  medium,

  /// Far away or info-only → suppressed / slow
  low,
}

// ─── Per-zone obstacle info ──────────────────────────────────────────────────

class ZoneObstacle {
  final Zone zone;
  final NavDetectedObject object;

  const ZoneObstacle({required this.zone, required this.object});
}

// ─── Path boundary lines ─────────────────────────────────────────────────────

/// Two normalised x-coordinates representing the left and right edges of the
/// safe walking corridor derived from obstacle positions.
class PathBoundary {
  /// Left edge of the safe walking path (0.0–1.0, from left of image).
  final double leftLineX;

  /// Right edge of the safe walking path (0.0–1.0, from left of image).
  final double rightLineX;

  /// Walkable corridor width as fraction of frame.
  double get corridorWidth => (rightLineX - leftLineX).clamp(0.0, 1.0);

  const PathBoundary({
    required this.leftLineX,
    required this.rightLineX,
  });

  @override
  String toString() =>
      'PathBoundary(left=${leftLineX.toStringAsFixed(2)}, '
      'right=${rightLineX.toStringAsFixed(2)}, '
      'width=${corridorWidth.toStringAsFixed(2)})';
}

// ─── Analysis result ─────────────────────────────────────────────────────────

class PathAnalysis {
  /// Whether the centre path is clear of critical/warning obstacles
  final bool isPathClear;

  /// Human-readable directional guidance (with clock positions)
  final String guidance;

  /// Hindi translation of guidance
  final String guidanceHi;

  /// Alert priority (0 = no alert, 1 = critical, 2 = warning, 3 = info)
  final int alertPriority;

  /// Voice urgency level for TTS control
  final VoiceUrgency urgency;

  /// All obstacles grouped by zone
  final List<ZoneObstacle> obstacles;

  /// The most dangerous object (if any)
  final NavDetectedObject? primaryThreat;

  /// Zone danger levels: true = has critical/warning obstacle
  final bool leftBlocked;
  final bool centerBlocked;
  final bool rightBlocked;

  /// Derived walkable-path boundary
  final PathBoundary pathBoundary;

  /// Closest obstacle distance (metres), null if none
  final double? closestDistance;

  /// Distance label for the closest threat (in steps)
  final String? closestDistanceLabel;

  /// Safe direction computed from depth map analysis
  final SafeDirection safeDirection;

  const PathAnalysis({
    required this.isPathClear,
    required this.guidance,
    required this.guidanceHi,
    required this.alertPriority,
    required this.urgency,
    required this.obstacles,
    this.primaryThreat,
    required this.leftBlocked,
    required this.centerBlocked,
    required this.rightBlocked,
    required this.pathBoundary,
    this.closestDistance,
    this.closestDistanceLabel,
    this.safeDirection = SafeDirection.straightAhead,
  });
}

// ─── Clock position helpers ──────────────────────────────────────────────────

/// Convert a zone/direction to a clock-position string.
class ClockDirection {
  // ── Zone-based directions ──
  static const String left = "9 o'clock";
  static const String slightLeft = "10 o'clock";
  static const String keepLeft = "10 o'clock";
  static const String ahead = "12 o'clock";
  static const String slightRight = "2 o'clock";
  static const String keepRight = "2 o'clock";
  static const String right = "3 o'clock";
  static const String sharpLeft = "8 o'clock";
  static const String sharpRight = "4 o'clock";
  static const String behind = "6 o'clock";

  // Hindi translations
  static const String leftHi = "9 बजे की दिशा";
  static const String slightLeftHi = "10 बजे की दिशा";
  static const String keepLeftHi = "10 बजे की दिशा";
  static const String aheadHi = "12 बजे की दिशा";
  static const String slightRightHi = "2 बजे की दिशा";
  static const String keepRightHi = "2 बजे की दिशा";
  static const String rightHi = "3 बजे की दिशा";
  static const String sharpLeftHi = "8 बजे की दिशा";
  static const String sharpRightHi = "4 बजे की दिशा";
  static const String behindHi = "6 बजे की दिशा";

  /// Convert a SafeDirection's clock position to English text.
  static String fromClockPos(int clockPos) => "$clockPos o'clock";
  static String fromClockPosHi(int clockPos) => "$clockPos बजे की दिशा";
}

// ─── Service ─────────────────────────────────────────────────────────────────

class PathAnalyzerService {
  // Zone boundaries (fraction of image width)
  static const double _leftEnd = 0.33;
  static const double _rightStart = 0.66;

  // Cooldown tracking to avoid repeating guidance
  String _lastGuidance = '';
  DateTime _lastGuidanceTime = DateTime(2000);

  // Last spoken objects — to suppress repeated announcements
  Set<String> _lastAnnouncedObjects = {};
  DateTime _lastInfoTime = DateTime(2000);

  /// Analyzes the frame detections and generates navigation guidance.
  /// Converts visual positions into actionable voice prompts with urgency.
  /// Uses clock-position directions and step-based distances.
  PathAnalysis analyze(
    List<NavDetectedObject> detections, {
    String? structuralBlocker,
    SafeDirection? safeDirection,
  }) {
    final safeDirValue = safeDirection ?? SafeDirection.straightAhead;

    // ── Structural blocker override ─────────────────────────────────────────
    if (structuralBlocker != null) {
      String enGuidance;
      String hiGuidance;

      if (structuralBlocker == 'door') {
        enGuidance = 'Door in front of you. Open the door.';
        hiGuidance = 'सामने दरवाज़ा है। कृपया दरवाज़ा खोलें।';
      } else if (structuralBlocker == 'wall') {
        enGuidance = "Wall in front of you. Move to ${ClockDirection.left} or ${ClockDirection.right}.";
        hiGuidance = "सामने दीवार है। ${ClockDirection.leftHi} या ${ClockDirection.rightHi} मुड़ें।";
      } else {
        enGuidance = "Path blocked by $structuralBlocker. Move to ${ClockDirection.left} or ${ClockDirection.right}.";
        hiGuidance = "सामने $structuralBlocker है। ${ClockDirection.leftHi} या ${ClockDirection.rightHi} मुड़ें।";
      }

      return PathAnalysis(
        isPathClear: false,
        guidance: enGuidance,
        guidanceHi: hiGuidance,
        alertPriority: 1,
        urgency: VoiceUrgency.critical,
        obstacles: [],
        primaryThreat: null,
        leftBlocked: true,
        centerBlocked: true,
        rightBlocked: true,
        pathBoundary: const PathBoundary(leftLineX: 0.5, rightLineX: 0.5),
        closestDistance: 0.5,
        closestDistanceLabel: '< 1 step',
        safeDirection: safeDirValue,
      );
    }

    // ── No detections → all clear ───────────────────────────────────────────
    if (detections.isEmpty) {
      return PathAnalysis(
        isPathClear: true,
        guidance: "Path is clear. Walk straight, ${ClockDirection.ahead}.",
        guidanceHi: "रास्ता साफ है। सीधे चलें, ${ClockDirection.aheadHi}।",
        alertPriority: 0,
        urgency: VoiceUrgency.low,
        obstacles: const [],
        leftBlocked: false,
        centerBlocked: false,
        rightBlocked: false,
        pathBoundary: const PathBoundary(leftLineX: 0.10, rightLineX: 0.90),
        safeDirection: safeDirValue,
      );
    }

    // ── Classify each detection into a zone ──────────────────────────────────
    final obstacles = <ZoneObstacle>[];
    final leftObjects = <NavDetectedObject>[];
    final centerObjects = <NavDetectedObject>[];
    final rightObjects = <NavDetectedObject>[];

    for (final det in detections) {
      final cx = det.centerX;
      Zone zone;
      if (cx < _leftEnd) {
        zone = Zone.left;
        leftObjects.add(det);
      } else if (cx > _rightStart) {
        zone = Zone.right;
        rightObjects.add(det);
      } else {
        zone = Zone.center;
        centerObjects.add(det);
      }
      obstacles.add(ZoneObstacle(zone: zone, object: det));
    }

    // ── Determine zone blockage (only critical + warning count) ──────────────
    bool hasBlocker(List<NavDetectedObject> objs) =>
        objs.any((o) =>
            o.dangerLevel == DangerLevel.critical ||
            o.dangerLevel == DangerLevel.warning);

    final leftBlocked = hasBlocker(leftObjects);
    final centerBlocked = hasBlocker(centerObjects);
    final rightBlocked = hasBlocker(rightObjects);

    // ── Derive path boundary lines ──────────────────────────────────────────
    final pathBoundary = _derivePathBoundary(detections, leftBlocked, rightBlocked);

    // ── Find most dangerous + closest object ────────────────────────────────
    NavDetectedObject? primaryThreat;
    double? closestDist;
    String? closestDistLabel;

    for (final det in detections) {
      if (det.dangerLevel == DangerLevel.critical ||
          det.dangerLevel == DangerLevel.warning) {
        if (primaryThreat == null ||
            det.estimatedDistance < primaryThreat.estimatedDistance) {
          primaryThreat = det;
        }
      }
      if (closestDist == null || det.estimatedDistance < closestDist) {
        closestDist = det.estimatedDistance;
        closestDistLabel = det.distanceLabel;
      }
    }
    primaryThreat ??= detections.first;

    // ── Determine voice urgency from proximity ──────────────────────────────
    final urgency = _computeUrgency(primaryThreat);

    // ── Generate guidance with clock positions ──────────────────────────────
    String guidance;
    String guidanceHi;
    int alertPriority;

    // Use safe direction's clock position for move guidance
    final safeClock = ClockDirection.fromClockPos(safeDirValue.clockPosition);
    final safeClockHi = ClockDirection.fromClockPosHi(safeDirValue.clockPosition);

    // Check for immediate critical danger
    if (primaryThreat.dangerLevel == DangerLevel.critical) {
      final label = primaryThreat.label;
      final labelHi = primaryThreat.labelLabel;
      final dist = primaryThreat.distanceLabel;
      final zone = primaryThreat.centerX < _leftEnd
          ? ClockDirection.left
          : primaryThreat.centerX > _rightStart
              ? ClockDirection.right
              : ClockDirection.ahead;
      final zoneHi = primaryThreat.centerX < _leftEnd
          ? ClockDirection.leftHi
          : primaryThreat.centerX > _rightStart
              ? ClockDirection.rightHi
              : ClockDirection.aheadHi;

      if (primaryThreat.proximityZone == ProximityZone.veryClose) {
        guidance = 'Stop! $label very close at $zone!';
        guidanceHi = 'रुकें! $labelHi बहुत करीब $zoneHi!';
        alertPriority = 1;
      } else {
        guidance = 'Warning! $label at $zone, $dist.';
        guidanceHi = 'सावधान! $labelHi $zoneHi, $dist।';
        alertPriority = 1;
      }

      // Add directional instruction using safe direction from depth map
      if (zone == ClockDirection.ahead) {
        if (!leftBlocked && !rightBlocked) {
          guidance += ' Move to $safeClock.';
          guidanceHi += ' $safeClockHi जाएं।';
        } else if (!leftBlocked) {
          guidance += " Move to ${ClockDirection.left}.";
          guidanceHi += " ${ClockDirection.leftHi} जाएं।";
        } else if (!rightBlocked) {
          guidance += " Move to ${ClockDirection.right}.";
          guidanceHi += " ${ClockDirection.rightHi} जाएं।";
        } else {
          guidance += ' Stop! All paths blocked.';
          guidanceHi += ' रुकें! सभी रास्ते बंद हैं।';
        }
      } else if (zone == ClockDirection.left) {
        guidance += " Move to ${ClockDirection.right} to avoid.";
        guidanceHi += " बचने के लिए ${ClockDirection.rightHi} जाएं।";
      } else if (zone == ClockDirection.right) {
        guidance += " Move to ${ClockDirection.left} to avoid.";
        guidanceHi += " बचने के लिए ${ClockDirection.leftHi} जाएं।";
      }
    }
    // Centre path is blocked by obstacle
    else if (centerBlocked) {
      alertPriority = 2;
      final centerLabel = centerObjects
          .where((o) =>
              o.dangerLevel == DangerLevel.critical ||
              o.dangerLevel == DangerLevel.warning)
          .map((o) => o.label)
          .join(', ');
      final centerLabelHi = centerObjects
          .where((o) =>
              o.dangerLevel == DangerLevel.critical ||
              o.dangerLevel == DangerLevel.warning)
          .map((o) => o.labelLabel)
          .join(', ');
      final centerDist = centerObjects
          .where((o) =>
              o.dangerLevel == DangerLevel.critical ||
              o.dangerLevel == DangerLevel.warning)
          .map((o) => o.distanceLabel)
          .firstOrNull ?? '';

      if (!leftBlocked && !rightBlocked) {
        // Use depth-map-derived safe direction
        guidance = '$centerLabel ahead ($centerDist). Move to $safeClock.';
        guidanceHi = 'सामने $centerLabelHi ($centerDist)। $safeClockHi जाएं।';
      } else if (!leftBlocked) {
        guidance = "$centerLabel ahead ($centerDist). Move to ${ClockDirection.left}.";
        guidanceHi = "सामने $centerLabelHi ($centerDist)। ${ClockDirection.leftHi} जाएं।";
      } else if (!rightBlocked) {
        guidance = "$centerLabel ahead ($centerDist). Move to ${ClockDirection.right}.";
        guidanceHi = "सामने $centerLabelHi ($centerDist)। ${ClockDirection.rightHi} जाएं।";
      } else {
        guidance = 'Path blocked in all directions. Stop and wait.';
        guidanceHi = 'सभी दिशाओं में रास्ता बंद। रुकें और प्रतीक्षा करें।';
      }
    }
    // Path is mostly clear — informational
    else {
      alertPriority = 3;
      final objectNames = detections
          .take(3)
          .map((d) => d.label)
          .toSet()
          .join(', ');
      final objectNamesHi = detections
          .take(3)
          .map((d) => d.labelLabel)
          .toSet()
          .join(', ');

      if (leftBlocked) {
        guidance = "Path clear ahead. $objectNames at ${ClockDirection.left}. Keep to ${ClockDirection.keepRight}.";
        guidanceHi = "रास्ता साफ है। ${ClockDirection.leftHi} पर $objectNamesHi। ${ClockDirection.keepRightHi} पर चलें।";
      } else if (rightBlocked) {
        guidance = "Path clear ahead. $objectNames at ${ClockDirection.right}. Keep to ${ClockDirection.keepLeft}.";
        guidanceHi = "रास्ता साफ है। ${ClockDirection.rightHi} पर $objectNamesHi। ${ClockDirection.keepLeftHi} पर चलें।";
      } else {
        guidance = "Walk straight, ${ClockDirection.ahead}. Nearby: $objectNames.";
        guidanceHi = "सीधे चलें, ${ClockDirection.aheadHi}। आसपास: $objectNamesHi।";
      }
    }

    return PathAnalysis(
      isPathClear: !centerBlocked,
      guidance: guidance,
      guidanceHi: guidanceHi,
      alertPriority: alertPriority,
      urgency: urgency,
      obstacles: obstacles,
      primaryThreat: primaryThreat,
      leftBlocked: leftBlocked,
      centerBlocked: centerBlocked,
      rightBlocked: rightBlocked,
      pathBoundary: pathBoundary,
      closestDistance: closestDist,
      closestDistanceLabel: closestDistLabel,
      safeDirection: safeDirValue,
    );
  }

  // ── Path boundary derivation ──────────────────────────────────────────────

  PathBoundary _derivePathBoundary(
    List<NavDetectedObject> detections,
    bool leftBlocked,
    bool rightBlocked,
  ) {
    double leftLine = 0.08;
    double rightLine = 0.92;

    final blockers = detections.where((d) =>
        d.dangerLevel == DangerLevel.critical ||
        d.dangerLevel == DangerLevel.warning).toList();

    if (blockers.isEmpty) {
      return PathBoundary(leftLineX: leftLine, rightLineX: rightLine);
    }

    for (final det in blockers) {
      if (det.centerX < _leftEnd) {
        leftLine = max(leftLine, det.boundingBox.right + 0.02);
      } else if (det.centerX > _rightStart) {
        rightLine = min(rightLine, det.boundingBox.left - 0.02);
      } else {
        final objLeft = det.boundingBox.left;
        final objRight = det.boundingBox.right;
        final gapLeft = objLeft;
        final gapRight = 1.0 - objRight;

        if (gapLeft > gapRight) {
          rightLine = min(rightLine, objLeft - 0.02);
        } else {
          leftLine = max(leftLine, objRight + 0.02);
        }
      }
    }

    leftLine = leftLine.clamp(0.0, 0.48);
    rightLine = rightLine.clamp(0.52, 1.0);
    if (leftLine >= rightLine) {
      leftLine = 0.48;
      rightLine = 0.52;
    }

    return PathBoundary(leftLineX: leftLine, rightLineX: rightLine);
  }

  // ── Urgency from proximity ────────────────────────────────────────────────

  VoiceUrgency _computeUrgency(NavDetectedObject threat) {
    switch (threat.proximityZone) {
      case ProximityZone.veryClose:
        return VoiceUrgency.critical;
      case ProximityZone.close:
        return VoiceUrgency.high;
      case ProximityZone.near:
        return VoiceUrgency.medium;
      case ProximityZone.far:
        return VoiceUrgency.low;
    }
  }

  /// Check if this guidance should be spoken (avoids repetitive announcements).
  bool shouldSpeak(PathAnalysis analysis) {
    final now = DateTime.now();

    if (analysis.urgency == VoiceUrgency.critical) {
      if (now.difference(_lastGuidanceTime).inMilliseconds >= 1500) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    if (analysis.urgency == VoiceUrgency.high ||
        analysis.alertPriority == 1) {
      if (now.difference(_lastGuidanceTime).inMilliseconds >= 2500) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    if (analysis.alertPriority == 2) {
      if (analysis.guidance != _lastGuidance ||
          now.difference(_lastGuidanceTime).inSeconds >= 4) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    final currentObjects =
        analysis.obstacles.map((o) => o.object.label).toSet();
    if (currentObjects.difference(_lastAnnouncedObjects).isNotEmpty ||
        now.difference(_lastInfoTime).inSeconds >= 10) {
      _lastAnnouncedObjects = currentObjects;
      _lastInfoTime = now;
      _lastGuidance = analysis.guidance;
      _lastGuidanceTime = now;
      return true;
    }
    return false;
  }

  /// Reset cooldowns (e.g., when user requests explicit update)
  void resetCooldowns() {
    _lastGuidance = '';
    _lastGuidanceTime = DateTime(2000);
    _lastAnnouncedObjects = {};
    _lastInfoTime = DateTime(2000);
  }
}
