// lib/services/face_embedding_service.dart
//
// Handles TFLite MobileFaceNet inference and image processing:
//   • YUV420 → RGB conversion
//   • Image rotation (for camera sensor orientation)
//   • Face cropping with padding
//   • 112×112 resize + normalisation ((pixel−128)/128)
//   • 192-d embedding extraction via TFLite
//   • Cosine similarity

import 'dart:math' show sqrt;
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceEmbeddingService {
  Interpreter? _interpreter;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Load the MobileFaceNet model from assets.
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      _interpreter =
          await Interpreter.fromAsset('assets/models/mobile_face_net.tflite');
      _isInitialized = true;
      debugPrint('[FaceEmb] MobileFaceNet loaded');
    } catch (e) {
      debugPrint('[FaceEmb] Failed to load model: $e');
      rethrow;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }

  // ── Image conversion ──────────────────────────────────────────────────────

  /// Convert a CameraImage (YUV420 / NV21) to an [img.Image] (RGB).
  img.Image convertCameraImage(CameraImage camera) {
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
        final int uVal =
            uvIndex < uPlane.bytes.length ? uPlane.bytes[uvIndex] : 128;
        final int vVal =
            uvIndex < vPlane.bytes.length ? vPlane.bytes[uvIndex] : 128;

        // Standard YUV → RGB
        int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128))
            .round()
            .clamp(0, 255);
        int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return image;
  }

  /// Rotate the image to match the device's upright orientation.
  img.Image rotateImage(img.Image image, int sensorOrientation) {
    if (sensorOrientation == 0) return image;
    return img.copyRotate(image, angle: sensorOrientation);
  }

  // ── Face crop & pre-processing ────────────────────────────────────────────

  /// Crop face region from the rotated RGB image, with padding.
  img.Image cropFace(img.Image image, Rect boundingBox) {
    final double padX = boundingBox.width * 0.15;
    final double padY = boundingBox.height * 0.15;

    int left = (boundingBox.left - padX).round().clamp(0, image.width - 1);
    int top = (boundingBox.top - padY).round().clamp(0, image.height - 1);
    int right =
        (boundingBox.right + padX).round().clamp(left + 1, image.width);
    int bottom =
        (boundingBox.bottom + padY).round().clamp(top + 1, image.height);

    int w = right - left;
    int h = bottom - top;

    // Safety: ensure valid dimensions
    if (w < 10 || h < 10) {
      w = (image.width * 0.3).round().clamp(10, image.width);
      h = (image.height * 0.3).round().clamp(10, image.height);
      left = (image.width - w) ~/ 2;
      top = (image.height - h) ~/ 2;
    }

    return img.copyCrop(image, x: left, y: top, width: w, height: h);
  }

  // ── TFLite inference ──────────────────────────────────────────────────────

  /// Run MobileFaceNet on a face image → 192-d L2-normalised embedding.
  List<double> getEmbedding(img.Image faceImage) {
    if (_interpreter == null) {
      throw StateError('Interpreter not initialised – call init() first');
    }

    // Resize to 112×112
    final resized = img.copyResize(faceImage, width: 112, height: 112);

    // Build input tensor [1, 112, 112, 3] normalised to [−1, 1]
    final input = List.generate(
      1,
      (_) => List.generate(
        112,
        (y) => List.generate(112, (x) {
          final pixel = resized.getPixel(x, y);
          return [
            (pixel.r.toDouble() - 128.0) / 128.0,
            (pixel.g.toDouble() - 128.0) / 128.0,
            (pixel.b.toDouble() - 128.0) / 128.0,
          ];
        }),
      ),
    );

    // Output tensor [1, 192]
    final output = List.generate(1, (_) => List.filled(192, 0.0));

    _interpreter!.run(input, output);

    // L2 normalise
    final embedding = output[0];
    final norm = sqrt(embedding.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) {
      for (int i = 0; i < embedding.length; i++) {
        embedding[i] /= norm;
      }
    }
    return embedding;
  }

  // ── Similarity ────────────────────────────────────────────────────────────

  /// Cosine similarity between two (ideally L2-normalised) embeddings.
  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }
}
