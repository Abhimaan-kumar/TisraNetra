// lib/services/scene_labeling_service.dart
//
// Detects broad structural and scene elements like "Wall" or "Door" that fill
// the camera frame, acting as a fallback for standard object detection when
// navigating directly toward plain barriers.

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

class SceneLabelingService {
  late final ImageLabeler _imageLabeler;

  // Confidence thresholds. A wall or door must be hugely prominent to count
  static const double _blockageConfidenceThreshold = 0.45;

  // Concepts that indicate a structural movement blocker
  static const Set<String> _structuralBlockers = {
    'Wall',
    'Door',
    'Gate',
    'Fence',
  };

  SceneLabelingService() {
    _imageLabeler = ImageLabeler(options: ImageLabelerOptions());
  }

  void dispose() {
    _imageLabeler.close();
  }

  /// Processes the frame and returns the name of a blocking structure (e.g. "Wall")
  /// if one dominates the view, otherwise returns null.
  Future<String?> detectStructuralBlockage(InputImage inputImage) async {
    try {
      final labels = await _imageLabeler.processImage(inputImage);
      
      for (final label in labels) {
        if (_structuralBlockers.contains(label.label) &&
            label.confidence >= _blockageConfidenceThreshold) {
          debugPrint('[SceneLabeler] Blocker detected: \${label.label} (Conf: \${label.confidence})');
          return label.label.toLowerCase(); // 'wall', 'door', etc.
        }
      }
      return null;
    } catch (e) {
      debugPrint('[SceneLabeler] Error: \$e');
      return null;
    }
  }
}
