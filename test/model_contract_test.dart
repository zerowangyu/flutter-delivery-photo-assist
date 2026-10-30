import 'package:delivery_photo_assist/src/services/picodet_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown interpolation fails before opening a native session', () async {
    final detector = PicoDetDetector(
      const PicoDetModel(
        path: 'unused.onnx',
        labels: ['delivery_item'],
        iosInterpolation: 'unsupported',
      ),
    );
    await expectLater(detector.open(), throwsArgumentError);
  });

  test('cubic model size must satisfy both native implementations', () async {
    final detector = PicoDetDetector(
      const PicoDetModel(
        path: 'unused.onnx',
        labels: ['delivery_item'],
        inputSize: 640,
        iosInterpolation: 'opencv_cubic_uint8',
      ),
    );
    await expectLater(detector.open(), throwsArgumentError);
  });
}
