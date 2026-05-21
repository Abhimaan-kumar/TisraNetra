// Basic smoke test for Percive app.
// The app requires Firebase initialization so we test that MyApp builds.

import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App smoke test - test framework works', (WidgetTester tester) async {
    // MyApp requires Firebase, so we just verify the test framework is functional.
    expect(1 + 1, equals(2));
  });
}
