// lib/services/navigation_service.dart
//
// Google Maps-like voice-guided navigation for visually impaired users.
//
// Features:
//   ┌─────────────────────────────────────────────────────────┐
//   │ • Directions API route fetching (walking mode)          │
//   │ • Real-time GPS tracking with 5m distance filter        │
//   │ • Progressive distance announcements:                   │
//   │     "Turn left in 50 meters" → "Turn left in 20 meters" │
//   │ • Approach warnings: "Prepare to turn right"            │
//   │ • Dynamic rerouting when user deviates > 30m            │
//   │ • Live ETA updates based on walking speed               │
//   │ • Continuous "walk straight for X meters" updates        │
//   │ • Smart cooldown — avoids repetitive announcements       │
//   └─────────────────────────────────────────────────────────┘

import 'dart:convert';
import 'dart:async';
import 'dart:math' show sqrt, sin, cos, atan2, pi;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

// ─── Navigation step ─────────────────────────────────────────────────────────

class NavigationStep {
  final String instruction; // plain-text instruction
  final String distance;    // e.g. "200 m"
  final String duration;    // e.g. "3 mins"
  final int distanceMeters; // distance in metres (raw value)
  final int durationSeconds; // duration in seconds (raw value)
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? maneuver;   // e.g. "turn-right", "turn-left"

  const NavigationStep({
    required this.instruction,
    required this.distance,
    required this.duration,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.maneuver,
  });

  /// Friendly maneuver description for voice
  String get maneuverVoice {
    switch (maneuver) {
      case 'turn-left':
        return 'turn left';
      case 'turn-right':
        return 'turn right';
      case 'turn-slight-left':
        return 'bear left';
      case 'turn-slight-right':
        return 'bear right';
      case 'turn-sharp-left':
        return 'sharp left';
      case 'turn-sharp-right':
        return 'sharp right';
      case 'uturn-left':
      case 'uturn-right':
        return 'make a U-turn';
      case 'straight':
        return 'continue straight';
      case 'roundabout-left':
      case 'roundabout-right':
        return 'enter the roundabout';
      case 'merge':
        return 'merge';
      case 'fork-left':
        return 'take the left fork';
      case 'fork-right':
        return 'take the right fork';
      default:
        return 'continue';
    }
  }

  @override
  String toString() => '$instruction ($distance, $duration)';
}

// ─── Navigation state ────────────────────────────────────────────────────────

enum NavigationState {
  idle,
  fetchingRoute,
  navigating,
  rerouting,
  arrived,
  error,
}

// ─── Route info ──────────────────────────────────────────────────────────────

class RouteInfo {
  final String summary;
  final String totalDistance;
  final String totalDuration;
  final int totalDistanceMeters;
  final int totalDurationSeconds;
  final List<NavigationStep> steps;
  final String destinationAddress;
  final double destLat;
  final double destLng;

  const RouteInfo({
    required this.summary,
    required this.totalDistance,
    required this.totalDuration,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.steps,
    required this.destinationAddress,
    required this.destLat,
    required this.destLng,
  });
}

// ─── Live navigation snapshot ────────────────────────────────────────────────

/// Real-time navigation state exposed to the UI every position update.
class NavigationSnapshot {
  final NavigationStep currentStep;
  final int currentStepIndex;
  final int totalSteps;
  final double distanceToNextTurn; // metres
  final double distanceToDestination; // metres (remaining)
  final String eta; // estimated time of arrival string
  final int etaMinutes;
  final String currentVoiceInstruction;
  final bool isApproachingTurn; // within 30m of next maneuver

  const NavigationSnapshot({
    required this.currentStep,
    required this.currentStepIndex,
    required this.totalSteps,
    required this.distanceToNextTurn,
    required this.distanceToDestination,
    required this.eta,
    required this.etaMinutes,
    required this.currentVoiceInstruction,
    required this.isApproachingTurn,
  });
}

// ─── Service ─────────────────────────────────────────────────────────────────

class NavigationService {
  // Google Maps Directions API key
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY';

  // ── Navigation config ─────────────────────────────────────────────────────
  static const double _stepCompleteRadius = 15.0;   // metres to trigger next step
  static const double _rerouteThreshold = 40.0;     // metres off-route to trigger reroute
  static const double _approachDistance = 30.0;      // metres — "prepare to turn"
  static const double _avgWalkingSpeed = 1.2;        // m/s average walking speed

  // ── Progressive announcement thresholds (metres) ──────────────────────────
  static const List<int> _announcementThresholds = [200, 100, 50, 30, 15];

  NavigationState _state = NavigationState.idle;
  RouteInfo? _currentRoute;
  int _currentStepIndex = 0;
  StreamSubscription<Position>? _positionStream;
  Position? _lastPosition;
  String _destinationName = '';

  // ── Announcement tracking ─────────────────────────────────────────────────
  Set<int> _announcedThresholds = {};   // which distance thresholds we've spoken
  DateTime _lastRouteAnnounce = DateTime(2000);
  DateTime _lastStraightAnnounce = DateTime(2000);
  String _lastSpokenInstruction = '';
  bool _approachAnnounced = false;

  // ── Reroute throttle ──────────────────────────────────────────────────────
  DateTime _lastRerouteTime = DateTime(2000);
  int _rerouteCount = 0;

  // Callbacks
  void Function(String instruction, String instructionHi)? onInstruction;
  void Function(NavigationState state)? onStateChange;
  void Function(int stepIndex, int totalSteps)? onStepUpdate;
  void Function()? onArrived;
  void Function(NavigationSnapshot snapshot)? onNavigationUpdate;
  void Function(String message)? onReroute;

  NavigationState get state => _state;
  RouteInfo? get currentRoute => _currentRoute;
  int get currentStepIndex => _currentStepIndex;
  Position? get lastPosition => _lastPosition;

  NavigationStep? get currentStep {
    if (_currentRoute == null) return null;
    if (_currentStepIndex >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[_currentStepIndex];
  }

  /// Peek at the next step (for approach warnings)
  NavigationStep? get nextStep {
    if (_currentRoute == null) return null;
    final nextIdx = _currentStepIndex + 1;
    if (nextIdx >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[nextIdx];
  }

  String get progressText {
    if (_currentRoute == null) return '';
    return 'Step ${_currentStepIndex + 1} of ${_currentRoute!.steps.length}';
  }

  /// Get formatted remaining distance from current position
  String get remainingDistanceText {
    if (_currentRoute == null || _lastPosition == null) return '';
    final dist = _computeRemainingDistance();
    return _formatDistance(dist);
  }

  /// Live ETA in minutes
  int get etaMinutes {
    if (_lastPosition == null) return 0;
    final dist = _computeRemainingDistance();
    return (dist / _avgWalkingSpeed / 60).ceil();
  }

  /// Formatted ETA string
  String get etaText {
    final mins = etaMinutes;
    if (mins <= 0) return 'Arriving';
    if (mins == 1) return '1 min';
    if (mins < 60) return '$mins mins';
    final hours = mins ~/ 60;
    final remMins = mins % 60;
    return '${hours}h ${remMins}m';
  }

  // ── Location ──────────────────────────────────────────────────────────────

  /// Get current device position. Handles permission requests.
  Future<Position?> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[Nav] Location services disabled');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('[Nav] Location permission denied');
          return null;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        debugPrint('[Nav] Location permission permanently denied');
        return null;
      }

      Position? position;
      try {
        // Try high accuracy briefly
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
      } catch (e) {
        debugPrint('[Nav] Location timeout/error, trying fallback: $e');
        // Fallback 1: Last known
        position = await Geolocator.getLastKnownPosition();
        
        // Fallback 2: Low accuracy
        if (position == null) {
          try {
            position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.low,
                timeLimit: Duration(seconds: 5),
              ),
            );
          } catch (e2) {
             debugPrint('[Nav] All location fallbacks failed: $e2');
          }
        }
      }
      
      _lastPosition = position;
      return position;
    } catch (e) {
      debugPrint('[Nav] Setup Location error: $e');
      return null;
    }
  }

  // ── Route fetching ────────────────────────────────────────────────────────

  /// Fetch directions from current location to spoken destination.
  Future<RouteInfo?> getDirections(String destination) async {
    _setState(NavigationState.fetchingRoute);
    _destinationName = destination;

    try {
      final position = await getCurrentLocation();
      if (position == null) {
        _setState(NavigationState.error);
        return null;
      }

      final route = await _fetchRoute(
        '${position.latitude},${position.longitude}',
        destination,
      );

      if (route != null) {
        _setState(NavigationState.idle);
      } else {
        _setState(NavigationState.error);
      }
      return route;
    } catch (e) {
      debugPrint('[Nav] Directions error: $e');
      _setState(NavigationState.error);
      return null;
    }
  }

  /// Internal route fetch (used for both initial + reroute).
  Future<RouteInfo?> _fetchRoute(String origin, String destination) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=$origin'
      '&destination=${Uri.encodeComponent(destination)}'
      '&mode=walking'
      '&language=en'
      '&key=$_apiKey',
    );

    debugPrint('[Nav] Fetching directions: $origin → $destination');
    final response = await http.get(url).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      debugPrint('[Nav] API error: ${response.statusCode}');
      return null;
    }

    final json = jsonDecode(response.body);
    final status = json['status'];

    if (status != 'OK') {
      debugPrint('[Nav] Directions API status: $status');
      return null;
    }

    final route = json['routes'][0];
    final leg = route['legs'][0];

    final steps = <NavigationStep>[];
    for (final step in leg['steps']) {
      steps.add(NavigationStep(
        instruction: _stripHtml(step['html_instructions'] ?? ''),
        distance: step['distance']?['text'] ?? '',
        duration: step['duration']?['text'] ?? '',
        distanceMeters: (step['distance']?['value'] ?? 0) as int,
        durationSeconds: (step['duration']?['value'] ?? 0) as int,
        startLat: (step['start_location']?['lat'] ?? 0.0).toDouble(),
        startLng: (step['start_location']?['lng'] ?? 0.0).toDouble(),
        endLat: (step['end_location']?['lat'] ?? 0.0).toDouble(),
        endLng: (step['end_location']?['lng'] ?? 0.0).toDouble(),
        maneuver: step['maneuver'],
      ));
    }

    final destLat = (leg['end_location']?['lat'] ?? 0.0).toDouble();
    final destLng = (leg['end_location']?['lng'] ?? 0.0).toDouble();

    _currentRoute = RouteInfo(
      summary: route['summary'] ?? '',
      totalDistance: leg['distance']?['text'] ?? '',
      totalDuration: leg['duration']?['text'] ?? '',
      totalDistanceMeters: (leg['distance']?['value'] ?? 0) as int,
      totalDurationSeconds: (leg['duration']?['value'] ?? 0) as int,
      steps: steps,
      destinationAddress: leg['end_address'] ?? destination,
      destLat: destLat,
      destLng: destLng,
    );

    debugPrint(
        '[Nav] Route: ${_currentRoute!.totalDistance} / '
        '${_currentRoute!.totalDuration} / ${steps.length} steps');
    return _currentRoute;
  }

  // ── Navigation tracking ───────────────────────────────────────────────────

  /// Start turn-by-turn navigation with GPS tracking.
  void startNavigation() {
    if (_currentRoute == null || _currentRoute!.steps.isEmpty) return;

    _currentStepIndex = 0;
    _announcedThresholds = {};
    _approachAnnounced = false;
    _rerouteCount = 0;
    _lastSpokenInstruction = '';
    _setState(NavigationState.navigating);

    // Announce first instruction
    _announceCurrentStep(initial: true);

    // Start listening to position updates
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // update every 5 metres
      ),
    ).listen(_onPositionUpdate);
  }

  /// Stop navigation
  void stopNavigation() {
    _positionStream?.cancel();
    _positionStream = null;
    _currentStepIndex = 0;
    _currentRoute = null;
    _announcedThresholds = {};
    _approachAnnounced = false;
    _setState(NavigationState.idle);
  }

  void _onPositionUpdate(Position position) {
    _lastPosition = position;

    if (_currentRoute == null || state != NavigationState.navigating) return;

    final steps = _currentRoute!.steps;
    if (_currentStepIndex >= steps.length) return;

    final step = steps[_currentStepIndex];

    // ── 1. Check if we've completed the current step ────────────────────
    final distToStepEnd = _distanceMetres(
      position.latitude,
      position.longitude,
      step.endLat,
      step.endLng,
    );

    if (distToStepEnd < _stepCompleteRadius) {
      _advanceToNextStep(position);
      return;
    }

    // ── 2. Check for route deviation (reroute) ──────────────────────────
    _checkForReroute(position, step);

    // ── 3. Progressive distance announcements ───────────────────────────
    _progressiveAnnouncements(distToStepEnd, step);

    // ── 4. Approach warning for the NEXT step ──────────────────────────
    if (!_approachAnnounced && distToStepEnd < _approachDistance) {
      final next = nextStep;
      if (next != null && next.maneuver != null) {
        _approachAnnounced = true;
        final instruction = 'Prepare to ${next.maneuverVoice}.';
        final instructionHi = '${next.maneuverVoice} के लिए तैयार हों।';
        onInstruction?.call(instruction, instructionHi);
      }
    }

    // ── 5. Periodic "continue straight" reminders ───────────────────────
    _continueStraightReminder(distToStepEnd, step);

    // ── 6. Emit real-time snapshot ──────────────────────────────────────
    _emitSnapshot(position, distToStepEnd);
  }

  /// Advance to the next step.
  void _advanceToNextStep(Position position) {
    _currentStepIndex++;
    _announcedThresholds = {};
    _approachAnnounced = false;

    final steps = _currentRoute!.steps;

    if (_currentStepIndex >= steps.length) {
      // Check if we're actually near the destination
      final distToDest = _distanceMetres(
        position.latitude,
        position.longitude,
        _currentRoute!.destLat,
        _currentRoute!.destLng,
      );

      if (distToDest < 30) {
        _setState(NavigationState.arrived);
        onArrived?.call();
        _positionStream?.cancel();
        _positionStream = null;
      } else {
        // Not actually at destination yet — might need reroute
        _currentStepIndex = steps.length - 1;
      }
    } else {
      onStepUpdate?.call(_currentStepIndex, steps.length);
      _announceCurrentStep();
    }
  }

  /// Progressive "In X meters, turn left" announcements.
  void _progressiveAnnouncements(double distToStepEnd, NavigationStep step) {
    final now = DateTime.now();

    // Don't spam — minimum 3s between announcements
    if (now.difference(_lastRouteAnnounce).inSeconds < 3) return;

    for (final threshold in _announcementThresholds) {
      if (distToStepEnd <= threshold &&
          !_announcedThresholds.contains(threshold)) {
        _announcedThresholds.add(threshold);

        final next = nextStep;
        if (next != null && next.maneuver != null) {
          final roundedDist = _roundDistance(distToStepEnd);
          final instruction =
              'In $roundedDist, ${next.maneuverVoice}.';
          final instructionHi =
              '$roundedDist में, ${next.maneuverVoice}।';

          // Only speak if different from last
          if (instruction != _lastSpokenInstruction) {
            _lastSpokenInstruction = instruction;
            _lastRouteAnnounce = now;
            onInstruction?.call(instruction, instructionHi);
          }
        }
        break;
      }
    }
  }

  /// Every 15 seconds, remind user to continue straight if no turns coming up.
  void _continueStraightReminder(double distToStepEnd, NavigationStep step) {
    final now = DateTime.now();
    if (now.difference(_lastStraightAnnounce).inSeconds < 15) return;
    if (distToStepEnd < 60) return; // about to turn, skip "continue straight"

    _lastStraightAnnounce = now;
    final roundedDist = _roundDistance(distToStepEnd);
    final instruction = 'Continue straight for $roundedDist.';
    final instructionHi = '$roundedDist तक सीधे चलते रहें।';

    if (instruction != _lastSpokenInstruction) {
      _lastSpokenInstruction = instruction;
      onInstruction?.call(instruction, instructionHi);
    }
  }

  /// Check if user has deviated from the route and trigger reroute.
  void _checkForReroute(Position position, NavigationStep step) {
    // Calculate distance from user to the step line segment
    final distFromRoute = _distanceToSegment(
      position.latitude, position.longitude,
      step.startLat, step.startLng,
      step.endLat, step.endLng,
    );

    if (distFromRoute > _rerouteThreshold) {
      final now = DateTime.now();
      // Throttle rerouting — minimum 20s between reroutes
      if (now.difference(_lastRerouteTime).inSeconds < 20) return;
      // Limit to 5 reroutes to prevent loops
      if (_rerouteCount >= 5) return;

      _lastRerouteTime = now;
      _rerouteCount++;

      debugPrint('[Nav] Off-route by ${distFromRoute.toStringAsFixed(0)}m — rerouting');
      _handleReroute(position);
    }
  }

  /// Reroute from current position to original destination.
  Future<void> _handleReroute(Position position) async {
    _setState(NavigationState.rerouting);
    onReroute?.call('Recalculating route...');

    try {
      final origin = '${position.latitude},${position.longitude}';
      final route = await _fetchRoute(origin, _destinationName);

      if (route != null) {
        _currentStepIndex = 0;
        _announcedThresholds = {};
        _approachAnnounced = false;
        _lastSpokenInstruction = '';
        _setState(NavigationState.navigating);

        final instruction =
            'Route recalculated. ${route.totalDistance} remaining. '
            'In ${route.steps.first.distance}, ${route.steps.first.instruction}.';
        final instructionHi =
            'रास्ता फिर से तैयार। ${route.totalDistance} बाकी। '
            '${route.steps.first.distance} में, ${route.steps.first.instruction}।';
        onInstruction?.call(instruction, instructionHi);
      } else {
        _setState(NavigationState.navigating); // Fall back to existing route
        onReroute?.call('Could not recalculate. Continuing on current route.');
      }
    } catch (e) {
      debugPrint('[Nav] Reroute error: $e');
      _setState(NavigationState.navigating);
    }
  }

  /// Announce the current step with contextual information.
  void _announceCurrentStep({bool initial = false}) {
    if (_currentRoute == null) return;
    if (_currentStepIndex >= _currentRoute!.steps.length) return;

    final step = _currentRoute!.steps[_currentStepIndex];
    final remaining = _currentRoute!.steps.length - _currentStepIndex;

    String instruction;
    String instructionHi;

    if (initial) {
      // First instruction: include route overview
      instruction = 'Starting navigation. '
          '${step.instruction}. '
          '${_currentRoute!.totalDistance} to destination.';
      instructionHi = 'नेविगेशन शुरू। '
          '${step.instruction}। '
          'मंजिल तक ${_currentRoute!.totalDistance}।';
    } else {
      // Subsequent steps
      final eta = etaText;
      instruction = '${step.instruction}. '
          '${step.distance}. '
          '$remaining steps left. $eta to arrival.';
      instructionHi = '${step.instruction}। '
          '${step.distance}। '
          '$remaining कदम बाकी। पहुँचने में $eta।';
    }

    _lastSpokenInstruction = instruction;
    _lastRouteAnnounce = DateTime.now();
    onInstruction?.call(instruction, instructionHi);
  }

  /// Emit a real-time navigation snapshot for the UI.
  void _emitSnapshot(Position position, double distToStepEnd) {
    if (_currentRoute == null || currentStep == null) return;

    final remainingDist = _computeRemainingDistance();

    onNavigationUpdate?.call(NavigationSnapshot(
      currentStep: currentStep!,
      currentStepIndex: _currentStepIndex,
      totalSteps: _currentRoute!.steps.length,
      distanceToNextTurn: distToStepEnd,
      distanceToDestination: remainingDist,
      eta: etaText,
      etaMinutes: etaMinutes,
      currentVoiceInstruction: _lastSpokenInstruction,
      isApproachingTurn: distToStepEnd < _approachDistance,
    ));
  }

  // ── Remaining info ────────────────────────────────────────────────────────

  /// Get remaining distance/time info for voice announcement.
  String getRemainingInfo() {
    if (_currentRoute == null) return 'No active route.';
    if (_currentStepIndex >= _currentRoute!.steps.length) {
      return 'You have arrived.';
    }
    final remaining = _currentRoute!.steps.length - _currentStepIndex;
    final dist = _formatDistance(_computeRemainingDistance());
    final eta = etaText;
    return '$remaining steps remaining. '
        '$dist to destination. '
        'Estimated arrival in $eta.';
  }

  /// Compute total remaining distance from current position.
  double _computeRemainingDistance() {
    if (_currentRoute == null || _lastPosition == null) return 0;

    double remaining = 0;
    final steps = _currentRoute!.steps;

    // Distance from current position to end of current step
    if (_currentStepIndex < steps.length) {
      remaining += _distanceMetres(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        steps[_currentStepIndex].endLat,
        steps[_currentStepIndex].endLng,
      );
    }

    // Add remaining step distances
    for (int i = _currentStepIndex + 1; i < steps.length; i++) {
      remaining += steps[i].distanceMeters.toDouble();
    }

    return remaining;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setState(NavigationState newState) {
    _state = newState;
    onStateChange?.call(newState);
  }

  /// Strip HTML tags from Directions API instructions
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .trim();
  }

  /// Format a distance in metres to a human-readable string.
  String _formatDistance(double metres) {
    if (metres < 50) return '${metres.round()} meters';
    if (metres < 1000) return '${(metres / 10).round() * 10} meters';
    return '${(metres / 1000).toStringAsFixed(1)} kilometers';
  }

  /// Round distance to natural breakpoints for voice (e.g. "20 meters")
  String _roundDistance(double metres) {
    if (metres < 15) return '10 meters';
    if (metres < 25) return '20 meters';
    if (metres < 40) return '30 meters';
    if (metres < 60) return '50 meters';
    if (metres < 80) return '70 meters';
    if (metres < 120) return '100 meters';
    if (metres < 175) return '150 meters';
    if (metres < 250) return '200 meters';
    if (metres < 400) return '300 meters';
    if (metres < 750) return '500 meters';
    return '${(metres / 1000).toStringAsFixed(1)} kilometers';
  }

  /// Haversine distance in metres between two lat/lng points
  double _distanceMetres(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0; // metres
    final dLat = _toRadians(lat2 - lat1);
    final dLng = _toRadians(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  /// Distance from a point to a line segment (for off-route detection).
  double _distanceToSegment(
    double pLat, double pLng,
    double aLat, double aLng,
    double bLat, double bLng,
  ) {
    // Project point onto the segment and compute distance
    final ap = [pLat - aLat, pLng - aLng];
    final ab = [bLat - aLat, bLng - aLng];
    final ab2 = ab[0] * ab[0] + ab[1] * ab[1];

    if (ab2 == 0) return _distanceMetres(pLat, pLng, aLat, aLng);

    final t = ((ap[0] * ab[0] + ap[1] * ab[1]) / ab2).clamp(0.0, 1.0);
    final projLat = aLat + t * ab[0];
    final projLng = aLng + t * ab[1];

    return _distanceMetres(pLat, pLng, projLat, projLng);
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  void dispose() {
    _positionStream?.cancel();
    _positionStream = null;
  }
}
