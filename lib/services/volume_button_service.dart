import 'package:flutter/services.dart';

typedef VolumeButtonCallback = Future<void> Function();

class VolumeButtonService {
  static const platform = MethodChannel('com.lifelens.app/volumebutton');
  
  static final List<VolumeButtonService> _stack = [];
  static bool _handlerInitialized = false;

  VolumeButtonCallback? _onVolumeUp;
  VolumeButtonCallback? _onVolumeDown;

  /// Register callbacks for volume button events
  Future<void> initialize({
    required VolumeButtonCallback onVolumeUp,
    required VolumeButtonCallback onVolumeDown,
  }) async {
    _onVolumeUp = onVolumeUp;
    _onVolumeDown = onVolumeDown;

    if (!_stack.contains(this)) {
      _stack.add(this);
    } else {
      _stack.remove(this);
      _stack.add(this);
    }

    if (!_handlerInitialized) {
      _handlerInitialized = true;
      platform.setMethodCallHandler((call) async {
        if (_stack.isNotEmpty) {
          final activeService = _stack.last;
          if (call.method == 'onVolumeUp') {
            await activeService._onVolumeUp?.call();
          } else if (call.method == 'onVolumeDown') {
            await activeService._onVolumeDown?.call();
          }
        }
      });
    }
  }

  /// Update callbacks (useful when navigating between screens)
  void updateCallbacks({
    VolumeButtonCallback? onVolumeUp,
    VolumeButtonCallback? onVolumeDown,
  }) {
    if (onVolumeUp != null) _onVolumeUp = onVolumeUp;
    if (onVolumeDown != null) _onVolumeDown = onVolumeDown;
  }

  void dispose() {
    _onVolumeUp = null;
    _onVolumeDown = null;
    _stack.remove(this);
  }
}
