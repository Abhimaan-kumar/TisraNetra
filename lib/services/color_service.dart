import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class ColorResult {
  final String dominantColor;
  final List<String> allColors;
  final String description;
  final Color displayColor;

  ColorResult({
    required this.dominantColor,
    required this.allColors,
    required this.description,
    required this.displayColor,
  });
}

class NamedColor {
  final String name;
  final int r, g, b;
  const NamedColor(this.name, this.r, this.g, this.b);
  Color get color => Color.fromARGB(255, r, g, b);
}

class ColorService {
  static const List<NamedColor> _palette = [
    NamedColor('Red', 229, 57, 53),
    NamedColor('Orange', 251, 140, 0),
    NamedColor('Yellow', 253, 216, 53),
    NamedColor('Green', 67, 160, 71),
    NamedColor('Blue', 30, 136, 229),
    NamedColor('Purple', 142, 36, 170),
    NamedColor('Pink', 233, 30, 99),
    NamedColor('Brown', 109, 76, 65),
    NamedColor('Black', 33, 33, 33),
    NamedColor('White', 250, 250, 250),
    NamedColor('Grey', 117, 117, 117),
    NamedColor('Teal', 0, 137, 123),
    NamedColor('Navy', 26, 35, 126),
    NamedColor('Beige', 215, 204, 200),
  ];

  Future<ColorResult?> identifyColor(CameraImage image) async {
    // Fast center pixel sampling
    final int cx = image.width ~/ 2;
    final int cy = image.height ~/ 2;
    // Average a 21x21 block around the center to avoid noise
    int rSum = 0, gSum = 0, bSum = 0;
    int count = 0;
    
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = cy - 10; y <= cy + 10; y++) {
      for (int x = cx - 10; x <= cx + 10; x++) {
        if (x < 0 || x >= image.width || y < 0 || y >= image.height) continue;
        
        final int yIndex = y * yPlane.bytesPerRow + x;
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);

        final int yVal = yPlane.bytes[yIndex];
        final int uVal = uvIndex < uPlane.bytes.length ? uPlane.bytes[uvIndex] : 128;
        final int vVal = uvIndex < vPlane.bytes.length ? vPlane.bytes[uvIndex] : 128;

        int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).round().clamp(0, 255);
        int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        rSum += r;
        gSum += g;
        bSum += b;
        count++;
      }
    }
    
    if (count == 0) return null;
    
    final int avgR = rSum ~/ count;
    final int avgG = gSum ~/ count;
    final int avgB = bSum ~/ count;
    
    NamedColor closest = _palette.first;
    double minDist = double.infinity;
    
    for (final c in _palette) {
      final dist = _colorDistance(avgR, avgG, avgB, c.r, c.g, c.b);
      if (dist < minDist) {
        minDist = dist;
        closest = c;
      }
    }
    
    return ColorResult(
      dominantColor: closest.name.toLowerCase(),
      allColors: [closest.name.toLowerCase()],
      description: closest.name,
      displayColor: closest.color,
    );
  }

  double _colorDistance(int r1, int g1, int b1, int r2, int g2, int b2) {
    // Euclidean distance in RGB space
    return sqrt(pow(r1 - r2, 2) + pow(g1 - g2, 2) + pow(b1 - b2, 2));
  }
}