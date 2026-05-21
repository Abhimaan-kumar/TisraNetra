// lib/utils/image_utils.dart
//
// Shared image-processing utilities.
// Heavy computations run in a background isolate via [Isolate.run]
// so they never block the UI thread.

import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart' show compute;
import 'package:camera/camera.dart' show CameraImage;
import 'package:image/image.dart' as img;

/// Compute the Laplacian variance (sharpness score) of a JPEG image.
///
/// Runs in a background isolate via [compute] so the UI thread is never
/// blocked by the decode → resize → convolution pipeline.
///
/// Returns 0.0 if decoding fails.
Future<double> computeLaplacianVariance(Uint8List jpegBytes) {
  return compute(_laplacianVariance, jpegBytes);
}

/// Top-level function (required by [compute]) that performs the actual
/// Laplacian variance calculation.
double _laplacianVariance(Uint8List jpegBytes) {
  try {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) return 0;

    final small = img.copyResize(decoded, width: 200);
    final w = small.width;
    final h = small.height;

    // Build a grayscale intensity matrix
    final gray = List.generate(
      h,
      (y) => List.generate(w, (x) {
        final p = small.getPixel(x, y);
        return (p.r * 0.299 + p.g * 0.587 + p.b * 0.114).toDouble();
      }),
    );

    // 3×3 Laplacian kernel
    const kernel = [
      [0, 1, 0],
      [1, -4, 1],
      [0, 1, 0],
    ];

    double sumSq = 0;
    int count = 0;
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        double v = 0;
        for (int ky = 0; ky < 3; ky++) {
          for (int kx = 0; kx < 3; kx++) {
            v += kernel[ky][kx] * gray[y + ky - 1][x + kx - 1];
          }
        }
        sumSq += v * v;
        count++;
      }
    }
    return count == 0 ? 0 : sumSq / count;
  } catch (_) {
    return 0;
  }
}

/// Converts a [CameraImage] (typically YUV420) to NV21 format bytes.
/// Runs in a background isolate to prevent UI thread blocking.
Future<Uint8List> convertToNV21(CameraImage image) async {
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final Map<String, dynamic> data = {
    'yBytes': yPlane.bytes,
    'uBytes': uPlane.bytes,
    'vBytes': vPlane.bytes,
    'width': image.width,
    'height': image.height,
    'yBytesPerRow': yPlane.bytesPerRow,
    'uBytesPerRow': uPlane.bytesPerRow,
    'vBytesPerRow': vPlane.bytesPerRow,
    'uvPixelStride': uPlane.bytesPerPixel ?? 1,
  };

  return compute(_convertNV21Isolate, data);
}

/// Isolate entry point for NV21 conversion.
Uint8List _convertNV21Isolate(Map<String, dynamic> data) {
  final Uint8List yBytes = data['yBytes'];
  final Uint8List uBytes = data['uBytes'];
  final Uint8List vBytes = data['vBytes'];
  final int width = data['width'];
  final int height = data['height'];
  final int yBytesPerRow = data['yBytesPerRow'];
  final int uBytesPerRow = data['uBytesPerRow'];
  final int vBytesPerRow = data['vBytesPerRow'];
  final int uvPixelStride = data['uvPixelStride'];

  late final Uint8List nv21;

  if (uvPixelStride == 2) {
    final int yRowBytes = width;
    final int totalYBytes = yRowBytes * height;
    final int totalUVBytes = vBytes.length;
    nv21 = Uint8List(totalYBytes + totalUVBytes);
    if (yBytesPerRow == width) {
      nv21.setRange(0, totalYBytes, yBytes);
    } else {
      int dst = 0;
      for (int row = 0; row < height; row++) {
        final int src = row * yBytesPerRow;
        nv21.setRange(dst, dst + width, yBytes, src);
        dst += width;
      }
    }
    nv21.setRange(totalYBytes, totalYBytes + totalUVBytes, vBytes);
  } else {
    final int uvWidth = width ~/ 2;
    final int uvHeight = height ~/ 2;
    final int ySize = width * height;
    nv21 = Uint8List(ySize + uvWidth * uvHeight * 2);
    int pos = 0;
    for (int row = 0; row < height; row++) {
      final int offset = row * yBytesPerRow;
      for (int col = 0; col < width; col++) {
        nv21[pos++] = yBytes[offset + col];
      }
    }
    for (int row = 0; row < uvHeight; row++) {
      for (int col = 0; col < uvWidth; col++) {
        nv21[pos++] = vBytes[row * vBytesPerRow + col];
        nv21[pos++] = uBytes[row * uBytesPerRow + col];
      }
    }
  }
  return nv21;
}

/// Run camera image preprocessing (conversion, rotation, cropping, and resizing)
/// inside a background isolate to keep the main thread completely free from heavy image loops.
Future<img.Image> processCameraImageIsolate({
  required CameraImage image,
  required int sensorOrientation,
  Rect? cropRect,
  int? resizeWidth,
  int? resizeHeight,
}) async {
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final Map<String, dynamic> data = {
    'yBytes': yPlane.bytes,
    'uBytes': uPlane.bytes,
    'vBytes': vPlane.bytes,
    'width': image.width,
    'height': image.height,
    'yBytesPerRow': yPlane.bytesPerRow,
    'uBytesPerRow': uPlane.bytesPerRow,
    'vBytesPerRow': vPlane.bytesPerRow,
    'uvPixelStride': uPlane.bytesPerPixel ?? 1,
    'sensorOrientation': sensorOrientation,
    if (cropRect != null) ...{
      'cropLeft': cropRect.left,
      'cropTop': cropRect.top,
      'cropRight': cropRect.right,
      'cropBottom': cropRect.bottom,
    },
    if (resizeWidth != null) 'resizeWidth': resizeWidth,
    if (resizeHeight != null) 'resizeHeight': resizeHeight,
  };

  return compute(_processCameraImageIsolate, data);
}

img.Image _processCameraImageIsolate(Map<String, dynamic> data) {
  final Uint8List yBytes = data['yBytes'];
  final Uint8List uBytes = data['uBytes'];
  final Uint8List vBytes = data['vBytes'];
  final int w = data['width'];
  final int h = data['height'];
  final int yBytesPerRow = data['yBytesPerRow'];
  final int uBytesPerRow = data['uBytesPerRow'];
  final int vBytesPerRow = data['vBytesPerRow'];
  final int uvPixelStride = data['uvPixelStride'];
  final int sensorOrientation = data['sensorOrientation'];

  // 1. Convert YUV to RGB
  img.Image image = img.Image(width: w, height: h);

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int yIndex = y * yBytesPerRow + x;
      final int uvIndex = uvPixelStride * (x ~/ 2) + uBytesPerRow * (y ~/ 2);

      final int yVal = yBytes[yIndex];
      final int uVal = uvIndex < uBytes.length ? uBytes[uvIndex] : 128;
      final int vVal = uvIndex < vBytes.length ? vBytes[uvIndex] : 128;

      int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
      int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128))
          .round()
          .clamp(0, 255);
      int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

      image.setPixelRgb(x, y, r, g, b);
    }
  }

  // 2. Rotate if needed
  if (sensorOrientation != 0) {
    image = img.copyRotate(image, angle: sensorOrientation);
  }

  // 3. Crop if needed
  if (data.containsKey('cropLeft')) {
    final double cropLeft = data['cropLeft'];
    final double cropTop = data['cropTop'];
    final double cropRight = data['cropRight'];
    final double cropBottom = data['cropBottom'];

    final double padX = (cropRight - cropLeft) * 0.15;
    final double padY = (cropBottom - cropTop) * 0.15;

    int left = (cropLeft - padX).round().clamp(0, image.width - 1);
    int top = (cropTop - padY).round().clamp(0, image.height - 1);
    int right = (cropRight + padX).round().clamp(left + 1, image.width);
    int bottom = (cropBottom + padY).round().clamp(top + 1, image.height);

    int cropW = right - left;
    int cropH = bottom - top;

    // Safety: ensure valid dimensions
    if (cropW < 10 || cropH < 10) {
      cropW = (image.width * 0.3).round().clamp(10, image.width);
      cropH = (image.height * 0.3).round().clamp(10, image.height);
      left = (image.width - cropW) ~/ 2;
      top = (image.height - cropH) ~/ 2;
    }

    image = img.copyCrop(image, x: left, y: top, width: cropW, height: cropH);
  }

  // 4. Resize if needed
  if (data.containsKey('resizeWidth')) {
    final int resizeW = data['resizeWidth'];
    final int resizeH = data['resizeHeight'];
    image = img.copyResize(image, width: resizeW, height: resizeH);
  }

  return image;
}

