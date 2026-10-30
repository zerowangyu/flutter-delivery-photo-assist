import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:delivery_photo_assist/src/services/picodet_model.dart';
import 'package:delivery_photo_assist/src/services/frame_tensor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const custom = String.fromEnvironment('DELIVERY_MODEL_ASSET');
  const native = MethodChannel('delivery_photo_assist');
  Future<Map<dynamic, dynamic>> frame() async {
    const width = 320, height = 480;
    final Map<String, Object> args;
    if (Platform.isIOS) {
      const stride = width * 4 + 16;
      final bytes = Uint8List(stride * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = y * stride + x * 4;
          bytes[i + 2] = 255;
          bytes[i + 3] = 255;
        }
      }
      args = {
        'width': width,
        'height': height,
        'format': 'bgra8888',
        'planes': [
          {'bytes': bytes, 'rowStride': stride, 'pixelStride': 4},
        ],
      };
    } else {
      args = {
        'width': width,
        'height': height,
        'format': 'yuv420',
        'planes': [
          {
            'bytes': Uint8List(width * height)
              ..fillRange(0, width * height, 128),
            'rowStride': width,
            'pixelStride': 1,
          },
          {
            'bytes': Uint8List(width * height ~/ 4)
              ..fillRange(0, width * height ~/ 4, 128),
            'rowStride': width ~/ 2,
            'pixelStride': 1,
          },
          {
            'bytes': Uint8List(width * height ~/ 4)
              ..fillRange(0, width * height ~/ 4, 128),
            'rowStride': width ~/ 2,
            'pixelStride': 1,
          },
        ],
      };
    }
    return (await native.invokeMapMethod('prepareCameraFrame', {
      ...args,
      'rotation': 0,
      'inputSize': 320,
      if (custom.isNotEmpty) 'iosInterpolation': 'opencv_cubic_uint8',
      'prepareTensor': true,
    }))!;
  }

  testWidgets(
    'native preprocessing and S/XS ONNX inference run with independent tensor lifetimes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('本机模型验证'))),
      );
      final packet = await frame();
      expect(packet['width'], 320);
      expect(packet['height'], 480);
      final jpeg = packet['jpeg'] as Uint8List;
      expect(jpeg.take(2).toList(), [0xff, 0xd8]);
      final bytes = packet['tensor'] as Uint8List;
      final tensor = frameTensor(bytes);
      expect(tensor.length, 3 * 320 * 320);
      if (Platform.isIOS) {
        expect(tensor[0], closeTo((1 - .485) / .229, .02));
        expect(tensor[320 * 320], closeTo(-.456 / .224, .02));
        expect(tensor[2 * 320 * 320], closeTo(-.406 / .225, .02));
      } else {
        // YUV/JPEG 的范围换算因平台实现可落在 128～130；各通道仍应为中性灰。
        final gray = (tensor[0] * .229 + .485) * 255;
        expect(gray, inInclusiveRange(126, 132));
        for (final (channel, mean, std) in [
          (0, .485, .229),
          (1, .456, .224),
          (2, .406, .225),
        ]) {
          expect(
            tensor[channel * 320 * 320],
            closeTo((gray / 255 - mean) / std, .002),
          );
        }
      }
      final dir = await getApplicationSupportDirectory();
      final results = <String, Object>{};
      for (final base
          in custom.isEmpty ? ['picodet_s_320', 'picodet_xs_320'] : [custom]) {
        for (final ext in ['onnx', 'json']) {
          final data = await rootBundle.load('assets/models/$base.$ext');
          await File('${dir.path}/$base.$ext').writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        }
        final model = await PicoDetModel.fromFiles(
          modelPath: '${dir.path}/$base.onnx',
          manifestPath: '${dir.path}/$base.json',
        );
        final detector = PicoDetDetector(model);
        await detector.open();
        final samples = <double>[];
        try {
          for (var i = 0; i < 6; i++) {
            final watch = Stopwatch()..start();
            final objects = await detector.detect(tensor, .35);
            if (i > 0) samples.add(watch.elapsedMicroseconds / 1000);
            expect(objects.every((o) => o.isValid), isTrue);
          }
        } finally {
          await detector.close();
        }
        samples.sort();
        results[base] = {
          'inferenceRoundTripMs': samples,
          'scope':
              'synthetic input; simulator/device as run; excludes camera and preprocessing',
        };
      }
      final performance = await native.invokeMapMethod('performanceState');
      expect(performance, contains('thermalLevel'));
      debugPrint('PICODET_NATIVE_SMOKE ${jsonEncode(results)}');
    },
  );
}
