import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/volume_button_service.dart';

Future<void> sendVolumeEvent(String method) async {
  final response = Completer<ByteData?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        VolumeButtonService.platform.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        response.complete,
      );
  final reply = await response.future;
  if (reply != null) const StandardMethodCodec().decodeEnvelope(reply);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Only the active screen receives hardware events', () async {
    final home = VolumeButtonService();
    final feature = VolumeButtonService();
    addTearDown(home.dispose);
    addTearDown(feature.dispose);
    final events = <String>[];
    await home.initialize(
      onVolumeUp: () async => events.add('home-up'),
      onVolumeDown: () async => events.add('home-down'),
    );
    await feature.initialize(
      onVolumeUp: () async => events.add('feature-up'),
      onVolumeDown: () async => events.add('feature-down'),
    );
    await sendVolumeEvent('onVolumeUp');
    await sendVolumeEvent('onVolumeDown');
    expect(events, ['feature-up', 'feature-down']);
  });

  test('Leaving a feature restores home; disposal stops events', () async {
    final home = VolumeButtonService();
    final feature = VolumeButtonService();
    addTearDown(home.dispose);
    addTearDown(feature.dispose);
    final events = <String>[];
    await home.initialize(
      onVolumeUp: () async => events.add('home-up'),
      onVolumeDown: () async => events.add('home-down'),
    );
    await feature.initialize(
      onVolumeUp: () async => events.add('feature-up'),
      onVolumeDown: () async => events.add('feature-down'),
    );
    feature.dispose();
    await sendVolumeEvent('onVolumeUp');
    await sendVolumeEvent('onVolumeDown');
    expect(events, ['home-up', 'home-down']);
    home.dispose();
    await sendVolumeEvent('onVolumeUp');
    expect(events, ['home-up', 'home-down']);
  });

  test(
    'Re-registering a screen activates it without duplicate callbacks',
    () async {
      final home = VolumeButtonService();
      final feature = VolumeButtonService();
      addTearDown(home.dispose);
      addTearDown(feature.dispose);
      final events = <String>[];
      await home.initialize(
        onVolumeUp: () async => events.add('old-home-up'),
        onVolumeDown: () async => events.add('old-home-down'),
      );
      await feature.initialize(
        onVolumeUp: () async => events.add('feature-up'),
        onVolumeDown: () async => events.add('feature-down'),
      );
      await home.initialize(
        onVolumeUp: () async => events.add('new-home-up'),
        onVolumeDown: () async => events.add('new-home-down'),
      );
      await sendVolumeEvent('onVolumeUp');
      expect(events, ['new-home-up']);
      home.dispose();
      await sendVolumeEvent('onVolumeDown');
      expect(events, ['new-home-up', 'feature-down']);
    },
  );
}
