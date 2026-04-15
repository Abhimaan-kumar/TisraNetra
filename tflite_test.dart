import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  try {
    print('Loading model...');
    final modelFile = File('assets/models/ssd_mobilenet_v2.tflite');
    final interpreter = Interpreter.fromFile(modelFile);
    print('Input tensors: \${interpreter.getInputTensors()}');
    print('Output tensors: \${interpreter.getOutputTensors()}');
    
    // Create dummy image 300x300
    final _inputSize = 300;
    
    print('Building input tensor...');
    final input = List<List<List<List<int>>>>.generate(
      1,
      (_) => List<List<List<int>>>.generate(
        _inputSize,
        (y) => List<List<int>>.generate(_inputSize, (x) {
          return <int>[128, 128, 128]; // gray pixel
        }),
      ),
    );
    
    print('Building output tensor...');
    final _maxDetections = 10;
    final outputLocations = List<List<List<double>>>.generate(
      1,
      (_) => List<List<double>>.generate(_maxDetections, (_) => List<double>.filled(4, 0.0)),
    );
    final outputClasses = List<List<double>>.generate(
      1,
      (_) => List<double>.filled(_maxDetections, 0.0),
    );
    final outputScores = List<List<double>>.generate(
      1,
      (_) => List<double>.filled(_maxDetections, 0.0),
    );
    final outputNumDet = List<double>.filled(1, 0.0);
    
    final outputs = {
      0: outputLocations,
      1: outputClasses,
      2: outputScores,
      3: outputNumDet,
    };
    
    print('Running inference...');
    interpreter.runForMultipleInputs([input], outputs);
    print('Inference success!');
    print('Num detections: \${outputNumDet[0]}');
    
  } catch (e, stackTrace) {
    print('CRASH: \$e');
    print(stackTrace);
  }
}
