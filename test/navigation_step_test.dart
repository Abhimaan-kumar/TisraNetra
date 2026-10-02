import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/navigation_service.dart';

void main() {
  final fixture =
      jsonDecode(File('samples/navigation_steps.json').readAsStringSync())
          as Map<String, dynamic>;
  final defaults = fixture['stepDefaults'] as Map<String, dynamic>;
  final cases = fixture['cases'] as List<dynamic>;

  group('Spoken walking directions', () {
    for (final item in cases.cast<Map<String, dynamic>>()) {
      test('${item['id']} maneuver gives an accessible spoken cue', () {
        final step = NavigationStep(
          instruction: item['instruction'] as String,
          distance: defaults['distance'] as String,
          duration: defaults['duration'] as String,
          distanceMeters: defaults['distanceMeters'] as int,
          durationSeconds: defaults['durationSeconds'] as int,
          startLat: (defaults['startLat'] as num).toDouble(),
          startLng: (defaults['startLng'] as num).toDouble(),
          endLat: (defaults['endLat'] as num).toDouble(),
          endLng: (defaults['endLng'] as num).toDouble(),
          maneuver: item['maneuver'] as String?,
        );
        expect(step.maneuverVoice, item['expectedVoice']);
      });
    }
  });
}
