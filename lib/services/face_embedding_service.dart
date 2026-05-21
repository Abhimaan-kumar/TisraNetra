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
