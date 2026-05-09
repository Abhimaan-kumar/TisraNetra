// lib/services/path_analyzer_service.dart
//
// Spatial analysis of detected objects for walking navigation.
// Divides the camera frame into 3 vertical zones (left / centre / right),
// derives approximate walkable-path boundary lines, estimates urgency from
// depth, and produces directional guidance + priority-based alerts.

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

  /// Human-readable directional guidance
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

  /// Distance label for the closest threat
  final String? closestDistanceLabel;

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
  });
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
  PathAnalysis analyze(List<NavDetectedObject> detections, {String? structuralBlocker}) {
    // ── Structural blocker override ─────────────────────────────────────────
    if (structuralBlocker != null) {
      String enGuidance;
      String hiGuidance;

      if (structuralBlocker == 'door') {
        enGuidance = 'Door in front of you. Open the door.';
        hiGuidance = 'सामने दरवाज़ा है। कृपया दरवाज़ा खोलें।';
      } else if (structuralBlocker == 'wall') {
        enGuidance = 'Wall in front of you. Move left or right.';
        hiGuidance = 'सामने दीवार है। बाईं या दाईं ओर मुड़ें।';
      } else {
        enGuidance = 'Path blocked by $structuralBlocker. Move left or right.';
        hiGuidance = 'सामने $structuralBlocker है। बाईं या दाईं ओर मुड़ें।';
      }

      return PathAnalysis(
        isPathClear: false,
        guidance: enGuidance,
        guidanceHi: hiGuidance,
        alertPriority: 1, // Critical priority
        urgency: VoiceUrgency.critical,
        obstacles: [],
        primaryThreat: null,
        leftBlocked: true,
        centerBlocked: true,
        rightBlocked: true,
        pathBoundary: const PathBoundary(leftLineX: 0.5, rightLineX: 0.5),
        closestDistance: 0.5,
        closestDistanceLabel: '< 1 m',
      );
    }

    // ── No detections → all clear ───────────────────────────────────────────
    if (detections.isEmpty) {
      return const PathAnalysis(
        isPathClear: true,
        guidance: 'Path is clear. Walk straight.',
        guidanceHi: 'रास्ता साफ है। सीधे चलें।',
        alertPriority: 0,
        urgency: VoiceUrgency.low,
        obstacles: [],
        leftBlocked: false,
        centerBlocked: false,
        rightBlocked: false,
        pathBoundary: PathBoundary(leftLineX: 0.10, rightLineX: 0.90),
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

    // ── Generate guidance ───────────────────────────────────────────────────
    String guidance;
    String guidanceHi;
    int alertPriority;

    // Check for immediate critical danger
    if (primaryThreat.dangerLevel == DangerLevel.critical) {
      final label = primaryThreat.label;
      final dist = primaryThreat.distanceLabel;
      final zone = primaryThreat.centerX < _leftEnd
          ? 'on the left'
          : primaryThreat.centerX > _rightStart
              ? 'on the right'
              : 'ahead';
      final zoneHi = primaryThreat.centerX < _leftEnd
          ? 'बाईं ओर'
          : primaryThreat.centerX > _rightStart
              ? 'दाईं ओर'
              : 'सामने';

      // Include distance in the guidance for urgency context
      if (primaryThreat.proximityZone == ProximityZone.veryClose) {
        guidance = 'Stop! $label very close $zone!';
        guidanceHi = 'रुकें! $label बहुत करीब $zoneHi!';
        alertPriority = 1;
      } else {
        guidance = 'Warning! $label $zone, $dist.';
        guidanceHi = 'सावधान! $label $zoneHi, $dist।';
        alertPriority = 1;
      }

      // Add directional instruction
      if (zone == 'ahead') {
        if (!leftBlocked && !rightBlocked) {
          guidance += ' Move to either side.';
          guidanceHi += ' किसी भी तरफ हट जाएं।';
        } else if (!leftBlocked) {
          guidance += ' Move left.';
          guidanceHi += ' बाईं ओर जाएं।';
        } else if (!rightBlocked) {
          guidance += ' Move right.';
          guidanceHi += ' दाईं ओर जाएं।';
        } else {
          guidance += ' Stop! All paths blocked.';
          guidanceHi += ' रुकें! सभी रास्ते बंद हैं।';
        }
      } else if (zone == 'on the left') {
        guidance += ' Move right to avoid.';
        guidanceHi += ' बचने के लिए दाईं ओर जाएं।';
      } else if (zone == 'on the right') {
        guidance += ' Move left to avoid.';
        guidanceHi += ' बचने के लिए बाईं ओर जाएं।';
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
      final centerDist = centerObjects
          .where((o) =>
              o.dangerLevel == DangerLevel.critical ||
              o.dangerLevel == DangerLevel.warning)
          .map((o) => o.distanceLabel)
          .firstOrNull ?? '';

      if (!leftBlocked && !rightBlocked) {
        // Prefer the side with fewer obstacles
        if (leftObjects.length <= rightObjects.length) {
          guidance = '$centerLabel ahead ($centerDist). Move left.';
          guidanceHi = 'सामने $centerLabel ($centerDist)। बाईं ओर जाएं।';
        } else {
          guidance = '$centerLabel ahead ($centerDist). Move right.';
          guidanceHi = 'सामने $centerLabel ($centerDist)। दाईं ओर जाएं।';
        }
      } else if (!leftBlocked) {
        guidance = '$centerLabel ahead ($centerDist). Move left.';
        guidanceHi = 'सामने $centerLabel ($centerDist)। बाईं ओर जाएं।';
      } else if (!rightBlocked) {
        guidance = '$centerLabel ahead ($centerDist). Move right.';
        guidanceHi = 'सामने $centerLabel ($centerDist)। दाईं ओर जाएं।';
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

      if (leftBlocked) {
        guidance = 'Path clear ahead. $objectNames on the left. Keep right.';
        guidanceHi = 'रास्ता साफ है। बाईं ओर $objectNames। दाईं ओर चलें।';
      } else if (rightBlocked) {
        guidance = 'Path clear ahead. $objectNames on the right. Keep left.';
        guidanceHi = 'रास्ता साफ है। दाईं ओर $objectNames। बाईं ओर चलें।';
      } else {
        guidance = 'Walk straight. Nearby: $objectNames.';
        guidanceHi = 'सीधे चलें। आसपास: $objectNames।';
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
    );
  }

  // ── Path boundary derivation ──────────────────────────────────────────────

  /// Derives the left and right boundary lines of the safe walking corridor
  /// by analysing obstacle positions.  Obstacles push the walkable corridor
  /// away from them (inner edges of bounding boxes define the boundary).
  PathBoundary _derivePathBoundary(
    List<NavDetectedObject> detections,
    bool leftBlocked,
    bool rightBlocked,
  ) {
    // Default full-width corridor
    double leftLine = 0.08;
    double rightLine = 0.92;

    // Only consider critical/warning-level obstacles for boundary derivation
    final blockers = detections.where((d) =>
        d.dangerLevel == DangerLevel.critical ||
        d.dangerLevel == DangerLevel.warning).toList();

    if (blockers.isEmpty) {
      return PathBoundary(leftLineX: leftLine, rightLineX: rightLine);
    }

    // Objects on the left push the left boundary rightward
    for (final det in blockers) {
      if (det.centerX < _leftEnd) {
        // Left-side obstacle: safe corridor starts after its right edge
        leftLine = max(leftLine, det.boundingBox.right + 0.02);
      } else if (det.centerX > _rightStart) {
        // Right-side obstacle: safe corridor ends before its left edge
        rightLine = min(rightLine, det.boundingBox.left - 0.02);
      } else {
        // Centre obstacle: narrow the corridor from both sides proportionally
        final objLeft = det.boundingBox.left;
        final objRight = det.boundingBox.right;
        // Push boundaries inward toward the wider gap
        final gapLeft = objLeft;       // space to the left of the object
        final gapRight = 1.0 - objRight; // space to the right

        if (gapLeft > gapRight) {
          // More room on the left — push right boundary left
          rightLine = min(rightLine, objLeft - 0.02);
        } else {
          // More room on the right — push left boundary right
          leftLine = max(leftLine, objRight + 0.02);
        }
      }
    }

    // Ensure sanity
    leftLine = leftLine.clamp(0.0, 0.48);
    rightLine = rightLine.clamp(0.52, 1.0);
    if (leftLine >= rightLine) {
      // Corridor collapsed — place lines at the centre
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
  /// Returns true if guidance is new or enough time has passed.
  /// Uses urgency-aware cooldowns: critical = shorter cooldown.
  bool shouldSpeak(PathAnalysis analysis) {
    final now = DateTime.now();

    // Critical / very-close alerts always speak (with 1.5s cooldown)
    if (analysis.urgency == VoiceUrgency.critical) {
      if (now.difference(_lastGuidanceTime).inMilliseconds >= 1500) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    // High urgency: speak if guidance changed, or after 2.5s cooldown
    if (analysis.urgency == VoiceUrgency.high ||
        analysis.alertPriority == 1) {
      if (now.difference(_lastGuidanceTime).inMilliseconds >= 2500) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    // Medium / warning: speak if guidance changed, or after 4s cooldown
    if (analysis.alertPriority == 2) {
      if (analysis.guidance != _lastGuidance ||
          now.difference(_lastGuidanceTime).inSeconds >= 4) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    // Info / low urgency: speak only if objects changed or after 10s
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
