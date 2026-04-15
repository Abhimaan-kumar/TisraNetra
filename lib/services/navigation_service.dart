// lib/services/navigation_service.dart
//
// Google Directions API integration for destination-based navigation.
// Uses REST API (http package) + Geolocator for GPS tracking.
// Provides turn-by-turn voice instructions without a map widget.

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
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String? maneuver;   // e.g. "turn-right", "turn-left"

  const NavigationStep({
    required this.instruction,
    required this.distance,
    required this.duration,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.maneuver,
  });

  @override
  String toString() => '$instruction ($distance, $duration)';
}

// ─── Navigation state ────────────────────────────────────────────────────────

enum NavigationState { idle, fetchingRoute, navigating, arrived, error }

// ─── Route info ──────────────────────────────────────────────────────────────

class RouteInfo {
  final String summary;
  final String totalDistance;
  final String totalDuration;
  final List<NavigationStep> steps;
  final String destinationAddress;

  const RouteInfo({
    required this.summary,
    required this.totalDistance,
    required this.totalDuration,
    required this.steps,
    required this.destinationAddress,
  });
}

// ─── Service ─────────────────────────────────────────────────────────────────

class NavigationService {
  // Google Maps Directions API key
  // Using the same GCP project key — ensure Directions API is enabled
  static const String _apiKey = 'REDACTED_PRIVATE_API_KEY';

  NavigationState _state = NavigationState.idle;
  RouteInfo? _currentRoute;
  int _currentStepIndex = 0;
  StreamSubscription<Position>? _positionStream;
  Position? _lastPosition;

  // Callbacks
  void Function(String instruction, String instructionHi)? onInstruction;
  void Function(NavigationState state)? onStateChange;
  void Function(int stepIndex, int totalSteps)? onStepUpdate;
  void Function()? onArrived;

  NavigationState get state => _state;
  RouteInfo? get currentRoute => _currentRoute;
  int get currentStepIndex => _currentStepIndex;
  Position? get lastPosition => _lastPosition;

  NavigationStep? get currentStep {
    if (_currentRoute == null) return null;
    if (_currentStepIndex >= _currentRoute!.steps.length) return null;
    return _currentRoute!.steps[_currentStepIndex];
  }

  String get progressText {
    if (_currentRoute == null) return '';
    return 'Step ${_currentStepIndex + 1} of ${_currentRoute!.steps.length}';
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

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _lastPosition = position;
      return position;
    } catch (e) {
      debugPrint('[Nav] Location error: $e');
      return null;
    }
  }

  // ── Route fetching ────────────────────────────────────────────────────────

  /// Fetch directions from current location to spoken destination.
  Future<RouteInfo?> getDirections(String destination) async {
    _setState(NavigationState.fetchingRoute);

    try {
      // 1. Get current location
      final position = await getCurrentLocation();
      if (position == null) {
        _setState(NavigationState.error);
        return null;
      }

      final origin = '${position.latitude},${position.longitude}';

      // 2. Call Directions API
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
        _setState(NavigationState.error);
        return null;
      }

      final json = jsonDecode(response.body);
      final status = json['status'];

      if (status != 'OK') {
        debugPrint('[Nav] Directions API status: $status');
        _setState(NavigationState.error);
        return null;
      }

      // 3. Parse route
      final route = json['routes'][0];
      final leg = route['legs'][0];

      final steps = <NavigationStep>[];
      for (final step in leg['steps']) {
        steps.add(NavigationStep(
          instruction: _stripHtml(step['html_instructions'] ?? ''),
          distance: step['distance']?['text'] ?? '',
          duration: step['duration']?['text'] ?? '',
          startLat: (step['start_location']?['lat'] ?? 0.0).toDouble(),
          startLng: (step['start_location']?['lng'] ?? 0.0).toDouble(),
          endLat: (step['end_location']?['lat'] ?? 0.0).toDouble(),
          endLng: (step['end_location']?['lng'] ?? 0.0).toDouble(),
          maneuver: step['maneuver'],
        ));
      }

      _currentRoute = RouteInfo(
        summary: route['summary'] ?? '',
        totalDistance: leg['distance']?['text'] ?? '',
        totalDuration: leg['duration']?['text'] ?? '',
        steps: steps,
        destinationAddress: leg['end_address'] ?? destination,
      );

      debugPrint(
          '[Nav] Route: ${_currentRoute!.totalDistance} / ${_currentRoute!.totalDuration} / ${steps.length} steps');
      _setState(NavigationState.idle);
      return _currentRoute;
    } catch (e) {
      debugPrint('[Nav] Directions error: $e');
      _setState(NavigationState.error);
      return null;
    }
  }

  // ── Navigation tracking ───────────────────────────────────────────────────

  /// Start turn-by-turn navigation with GPS tracking.
  void startNavigation() {
    if (_currentRoute == null || _currentRoute!.steps.isEmpty) return;

    _currentStepIndex = 0;
    _setState(NavigationState.navigating);

    // Announce first instruction
    _announceCurrentStep();

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
    _setState(NavigationState.idle);
  }

  void _onPositionUpdate(Position position) {
    _lastPosition = position;

    if (_currentRoute == null || state != NavigationState.navigating) return;

    final steps = _currentRoute!.steps;
    if (_currentStepIndex >= steps.length) return;

    final currentStep = steps[_currentStepIndex];

    // Check distance to the end of current step
    final distToStepEnd = _distanceMetres(
      position.latitude,
      position.longitude,
      currentStep.endLat,
      currentStep.endLng,
    );

    // If within 15 metres of step end point, advance to next step
    if (distToStepEnd < 15) {
      _currentStepIndex++;

      if (_currentStepIndex >= steps.length) {
        // Arrived at destination
        _setState(NavigationState.arrived);
        onArrived?.call();
        _positionStream?.cancel();
        _positionStream = null;
      } else {
        onStepUpdate?.call(_currentStepIndex, steps.length);
        _announceCurrentStep();
      }
    }
  }

  void _announceCurrentStep() {
    if (_currentRoute == null) return;
    if (_currentStepIndex >= _currentRoute!.steps.length) return;

    final step = _currentRoute!.steps[_currentStepIndex];
    final instruction = 'In ${step.distance}, ${step.instruction}';
    final instructionHi = '${step.distance} में, ${step.instruction}';

    onInstruction?.call(instruction, instructionHi);
  }

  /// Get remaining distance/time info
  String getRemainingInfo() {
    if (_currentRoute == null) return 'No active route.';
    if (_currentStepIndex >= _currentRoute!.steps.length) {
      return 'You have arrived.';
    }
    final remaining = _currentRoute!.steps.length - _currentStepIndex;
    return '$remaining steps remaining. '
        'Total: ${_currentRoute!.totalDistance}, ${_currentRoute!.totalDuration}.';
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

  double _toRadians(double degrees) => degrees * pi / 180;

  void dispose() {
    _positionStream?.cancel();
    _positionStream = null;
  }
}
