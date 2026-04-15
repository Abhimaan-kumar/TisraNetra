// lib/services/path_analyzer_service.dart
//
// Spatial analysis of detected objects for walking navigation.
// Divides the camera frame into 3 vertical zones (left / centre / right)
// and produces directional guidance + priority-based alerts.

import 'nav_object_detection_service.dart';

// ─── Zone classification ─────────────────────────────────────────────────────

enum Zone { left, center, right }

// ─── Per-zone obstacle info ──────────────────────────────────────────────────

class ZoneObstacle {
  final Zone zone;
  final NavDetectedObject object;

  const ZoneObstacle({required this.zone, required this.object});
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

  /// All obstacles grouped by zone
  final List<ZoneObstacle> obstacles;

  /// The most dangerous object (if any)
  final NavDetectedObject? primaryThreat;

  /// Zone danger levels: true = has critical/warning obstacle
  final bool leftBlocked;
  final bool centerBlocked;
  final bool rightBlocked;

  const PathAnalysis({
    required this.isPathClear,
    required this.guidance,
    required this.guidanceHi,
    required this.alertPriority,
    required this.obstacles,
    this.primaryThreat,
    required this.leftBlocked,
    required this.centerBlocked,
    required this.rightBlocked,
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
  /// Converts visual positions into actionable voice prompts.
  PathAnalysis analyze(List<NavDetectedObject> detections, {String? structuralBlocker}) {
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
        obstacles: [],
        primaryThreat: null,
        leftBlocked: true,
        centerBlocked: true,
        rightBlocked: true,
      );
    }

    if (detections.isEmpty) {
      return const PathAnalysis(
        isPathClear: true,
        guidance: 'Path is clear. Walk straight.',
        guidanceHi: 'रास्ता साफ है। सीधे चलें।',
        alertPriority: 0,
        obstacles: [],
        leftBlocked: false,
        centerBlocked: false,
        rightBlocked: false,
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

    // ── Find most dangerous object ──────────────────────────────────────────
    NavDetectedObject? primaryThreat;
    for (final det in detections) {
      if (det.dangerLevel == DangerLevel.critical) {
        if (primaryThreat == null ||
            det.areaFraction > primaryThreat.areaFraction) {
          primaryThreat = det;
        }
      }
    }
    primaryThreat ??= detections.firstWhere(
      (d) => d.dangerLevel == DangerLevel.warning,
      orElse: () => detections.first,
    );

    // ── Generate guidance ───────────────────────────────────────────────────
    String guidance;
    String guidanceHi;
    int alertPriority;

    // Check for immediate critical danger
    if (primaryThreat.dangerLevel == DangerLevel.critical) {
      final label = primaryThreat.label;
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

      guidance = 'Warning! $label $zone.';
      guidanceHi = 'सावधान! $label $zoneHi।';
      alertPriority = 1;

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

      if (!leftBlocked && !rightBlocked) {
        // Prefer the side with fewer obstacles
        if (leftObjects.length <= rightObjects.length) {
          guidance = '$centerLabel ahead. Move left.';
          guidanceHi = 'सामने $centerLabel। बाईं ओर जाएं।';
        } else {
          guidance = '$centerLabel ahead. Move right.';
          guidanceHi = 'सामने $centerLabel। दाईं ओर जाएं।';
        }
      } else if (!leftBlocked) {
        guidance = '$centerLabel ahead. Move left.';
        guidanceHi = 'सामने $centerLabel। बाईं ओर जाएं।';
      } else if (!rightBlocked) {
        guidance = '$centerLabel ahead. Move right.';
        guidanceHi = 'सामने $centerLabel। दाईं ओर जाएं।';
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
        guidance = 'Path clear ahead. $objectNames on the left. Move right.';
        guidanceHi = 'रास्ता साफ है। बाईं ओर $objectNames। दाईं ओर जाएं।';
      } else if (rightBlocked) {
        guidance = 'Path clear ahead. $objectNames on the right. Move left.';
        guidanceHi = 'रास्ता साफ है। दाईं ओर $objectNames। बाईं ओर जाएं।';
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
      obstacles: obstacles,
      primaryThreat: primaryThreat,
      leftBlocked: leftBlocked,
      centerBlocked: centerBlocked,
      rightBlocked: rightBlocked,
    );
  }

  /// Check if this guidance should be spoken (avoids repetitive announcements).
  /// Returns true if guidance is new or enough time has passed.
  bool shouldSpeak(PathAnalysis analysis) {
    final now = DateTime.now();

    // Critical alerts always speak (with 2s cooldown)
    if (analysis.alertPriority == 1) {
      if (now.difference(_lastGuidanceTime).inSeconds >= 2) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    // Warning: speak if guidance changed, or after 4s cooldown
    if (analysis.alertPriority == 2) {
      if (analysis.guidance != _lastGuidance ||
          now.difference(_lastGuidanceTime).inSeconds >= 4) {
        _lastGuidance = analysis.guidance;
        _lastGuidanceTime = now;
        return true;
      }
      return false;
    }

    // Info: speak only if objects changed or after 10s
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
