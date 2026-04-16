import 'dart:ui' show Rect;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ── Detected object with normalized bounding box ─────────────────────────────
// All coords are 0.0–1.0 (fraction of image width/height)

class DetectedObject {
  final String name;
  final double left;   // x of top-left corner (0.0–1.0)
  final double top;    // y of top-left corner (0.0–1.0)
  final double width;  // box width  (0.0–1.0)
  final double height; // box height (0.0–1.0)

  const DetectedObject({
    required this.name,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

class ObjectRecognitionResult {
  final List<DetectedObject> objects;

  // Spoken text = just the object names joined
  String get spokenText {
    if (objects.isEmpty) return 'Nothing detected';
    final names = objects.map((o) => o.name).toList();
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  const ObjectRecognitionResult({required this.objects});

  bool isSimilarTo(ObjectRecognitionResult? other) {
    if (other == null) return false;
    final a = objects.map((o) => o.name.toLowerCase()).toSet();
    final b = other.objects.map((o) => o.name.toLowerCase()).toSet();
    if (a.isEmpty || b.isEmpty) return false;
    return a.intersection(b).length / a.length > 0.6;
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class ObjectRecognitionService {
  static const String _modelAsset = 'assets/models/ssd_mobilenet_v2.tflite';
  static const String _labelsAsset = 'assets/models/coco_labels.txt';
  static const int _inputSize = 300;
  static const double _confidenceThreshold = 0.50;

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final options = InterpreterOptions()..threads = 4;
      _interpreter = await Interpreter.fromAsset(_modelAsset, options: options);

      final labelsRaw = await rootBundle.loadString(_labelsAsset);
      _labels = labelsRaw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

      _isInitialized = true;
      debugPrint('[ObjRecog] Initialised');
    } catch (e) {
      debugPrint('[ObjRecog] Init failed: $e');
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }

  Future<ObjectRecognitionResult?> recognizeObjects(CameraImage cameraImage, int sensorOrientation) async {
    if (!_isInitialized || _interpreter == null) return null;

    try {
      final rgbImage = _convertCameraImage(cameraImage);
      final rotated = _rotateImage(rgbImage, sensorOrientation);
      final resized = img.copyResize(rotated, width: _inputSize, height: _inputSize);
      final input = _buildInputTensor(resized);

      final numLocations = _interpreter!.getOutputTensor(0).shape[1];
      final outputLocations = List<List<List<double>>>.generate(1, (_) => List<List<double>>.generate(numLocations, (_) => List<double>.filled(4, 0.0)));
      final outputClasses = List<List<double>>.generate(1, (_) => List<double>.filled(numLocations, 0.0));
      final outputScores = List<List<double>>.generate(1, (_) => List<double>.filled(numLocations, 0.0));
      final outputNumDet = List<double>.filled(1, 0.0);

      final outputs = {
        0: outputLocations,
        1: outputClasses,
        2: outputScores,
        3: outputNumDet,
      };

      _interpreter!.runForMultipleInputs([input], outputs);

      final numDetections = outputNumDet[0].toInt().clamp(0, numLocations);
      final objects = <DetectedObject>[];

      for (int i = 0; i < numDetections; i++) {
        final score = outputScores[0][i];
        if (score < _confidenceThreshold) continue;

        final classIdx = outputClasses[0][i].toInt();
        if (classIdx < 0 || classIdx >= _labels.length) continue;

        final label = _labels[classIdx];
        if (label.isEmpty || label == 'n/a') continue;

        final top = outputLocations[0][i][0].clamp(0.0, 1.0);
        final left = outputLocations[0][i][1].clamp(0.0, 1.0);
        final bottom = outputLocations[0][i][2].clamp(0.0, 1.0);
        final right = outputLocations[0][i][3].clamp(0.0, 1.0);

        if (right <= left || bottom <= top) continue;

        objects.add(DetectedObject(
          name: label,
          left: left,
          top: top,
          width: right - left,
          height: bottom - top,
        ));
      }

      // Sort by area size (larger = closer)
      objects.sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        return areaB.compareTo(areaA);
      });

      return ObjectRecognitionResult(objects: objects);
    } catch (e) {
      debugPrint('[ObjRecog] Detection error: $e');
      return null;
    }
  }

  img.Image _convertCameraImage(CameraImage camera) {
    final int w = camera.width;
    final int h = camera.height;
    final yPlane = camera.planes[0];
    final uPlane = camera.planes[1];
    final vPlane = camera.planes[2];
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final image = img.Image(width: w, height: h);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int yIndex = y * yPlane.bytesPerRow + x;
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);

        final int yVal = yPlane.bytes[yIndex];
        final int uVal = uvIndex < uPlane.bytes.length ? uPlane.bytes[uvIndex] : 128;
        final int vVal = uvIndex < vPlane.bytes.length ? vPlane.bytes[uvIndex] : 128;

        int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).round().clamp(0, 255);
        int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return image;
  }

  img.Image _rotateImage(img.Image image, int sensorOrientation) {
    if (sensorOrientation == 0) return image;
    return img.copyRotate(image, angle: sensorOrientation);
  }

  List<List<List<List<int>>>> _buildInputTensor(img.Image resized) {
    return List<List<List<List<int>>>>.generate(
      1,
      (_) => List<List<List<int>>>.generate(
        _inputSize,
        (y) => List<List<int>>.generate(_inputSize, (x) {
          final pixel = resized.getPixel(x, y);
          return <int>[pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        }),
      ),
    );
  }
}