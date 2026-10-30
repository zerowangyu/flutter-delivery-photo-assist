import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:delivery_photo_assist/src/domain/guidance.dart';
import 'package:delivery_photo_assist/src/services/delivery_camera.dart';
import 'package:delivery_photo_assist/src/services/picodet_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = PicoDetModel(path: 'fake.onnx', labels: ['delivery_item']);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraPlatform original;
  late _Camera platform;
  late _Detector detector;
  late DeliveryCameraController controller;
  late Directory temp;
  late List<String> errors;
  late List<Map<String, dynamic>> frames;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> initialize() => controller.initialize(
    _model,
    onFrame: frames.add,
    onError: errors.add,
    onReady: () {},
  );

  Future<void> flush() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('delivery-compatibility-');
    original = CameraPlatform.instance;
    platform = _Camera(temp);
    CameraPlatform.instance = platform;
    detector = _Detector();
    controller = DeliveryCameraController(detectorFactory: (_) => detector);
    errors = [];
    frames = [];
    messenger.setMockMethodCallHandler(deliveryNative, (call) async {
      if (call.method != 'prepareCameraFrame') return <String, Object>{};
      return {
        'width': 2,
        'height': 2,
        'tensor': Uint8List(3 * 320 * 320 * 4),
        'jpeg': Uint8List(1),
        'quality': <String, Object>{},
      };
    });
  });

  tearDown(() async {
    controller.dispose();
    await flush();
    CameraPlatform.instance = original;
    messenger.setMockMethodCallHandler(deliveryNative, null);
    await temp.delete(recursive: true);
    for (final stream in platform.streams.values) {
      await stream.close();
    }
    // camera 包使用 onCameraError.first；结束模拟设备前让其订阅正常完成。
    for (var id = 1; id <= platform.nextId; id++) {
      platform.errors.add(CameraErrorEvent(id, 'test ended'));
    }
    await flush();
    await platform.errors.close();
  });

  test(
    'unsupported optional camera controls preserve detection and capture',
    () async {
      platform.unsupportedControls = true;
      await initialize();
      expect(controller.cameraError, isNull);
      expect(controller.modelReady, isTrue);
      expect((await controller.getCameraZoomState())!['available'], isFalse);
      platform.emit();
      await flush();
      expect(frames.single['analysisMode'], 'detect');
      expect(await controller.captureDeliveryPhoto(), isNotNull);
      await controller.toggleTorch();
      expect(controller.isTorchEnabled, isFalse);
      await controller.pause();
      expect(
        platform.paused,
        isTrue,
        reason: 'flash failure must not skip pause',
      );
    },
  );

  test(
    'backgrounding during camera initialization stays paused until resume',
    () async {
      platform.initializationGate = Completer<void>();
      final pending = initialize();
      await flush();
      await controller.pause();
      platform.initializationGate!.complete();
      await pending;
      expect(platform.paused, isTrue);
      expect(platform.streamStarts, 0);
      await controller.resume();
      expect(platform.paused, isFalse);
      expect(platform.streamStarts, 1);
      platform.emit();
      await flush();
      expect(frames.single['analysisMode'], 'detect');
    },
  );

  test(
    'model finishing in background starts analysis on next resume',
    () async {
      detector.openGate = Completer<void>();
      final pending = initialize();
      await flush();
      expect(controller.isInitialized, isTrue);
      expect(await controller.captureDeliveryPhoto(), isNotNull);
      await controller.pause();
      detector.openGate!.complete();
      await pending;
      expect(platform.streamStarts, 0);
      await controller.resume();
      expect(platform.streamStarts, 1);
      platform.emit();
      await flush();
      expect(detector.inferences, 1);
    },
  );

  test(
    'superseded model load is closed and cannot replace the new model',
    () async {
      final first = detector..openGate = Completer<void>();
      final second = _Detector();
      var opens = 0;
      controller.dispose();
      controller = DeliveryCameraController(
        detectorFactory: (_) => opens++ == 0 ? first : second,
      );
      final old = initialize();
      await flush();
      final latest = initialize();
      first.openGate!.complete();
      await Future.wait([old, latest]);
      expect(first.closes, 1);
      expect(platform.disposedIds, contains(1));
      expect(controller.camera!.cameraId, 2);
      platform.emit();
      await flush();
      expect(second.inferences, 1);
      expect(first.inferences, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'dispose during model load releases late session without starting stream',
    () async {
      detector.openGate = Completer<void>();
      final pending = initialize();
      await flush();
      controller.dispose();
      detector.openGate!.complete();
      await pending;
      await flush();
      expect(detector.closes, 1);
      expect(platform.disposedIds, [1]);
      expect(platform.streamStarts, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'model load failure remains visible through quality-only frames and allows capture',
    () async {
      detector.failOpen = true;
      await initialize();
      expect(controller.modelReady, isFalse);
      platform.emit();
      await flush();
      expect(frames.single['analysisMode'], 'quality_only');
      expect(controller.modelError, isNotNull);
      expect(controller.cameraError, isNull);
      expect(await controller.captureDeliveryPhoto(), isNotNull);
    },
  );

  test(
    'transient inference error clears only after a successful inference',
    () async {
      detector.failDetect = true;
      await initialize();
      await controller.setStreamingConfig(const CameraAnalysisConfig(5));
      platform.emit();
      await flush();
      expect(controller.modelError, isNotNull);
      detector.failDetect = false;
      await Future<void>.delayed(const Duration(milliseconds: 210));
      platform.emit();
      await flush();
      expect(controller.modelError, isNull);
      expect(frames.single['analysisMode'], 'detect');
    },
  );

  test(
    'stream failure preserves camera capture and resume retries streaming',
    () async {
      platform.failStream = true;
      await initialize();
      expect(controller.modelError, isNotNull);
      expect(controller.cameraError, isNull);
      expect(await controller.captureDeliveryPhoto(), isNotNull);
      platform.failStream = false;
      await controller.pause();
      await controller.resume();
      platform.emit();
      await flush();
      expect(controller.modelError, isNull);
      expect(frames.single['analysisMode'], 'detect');
    },
  );

  test(
    'runtime zoom failure becomes unavailable instead of an uncaught error',
    () async {
      await initialize();
      platform.unsupportedControls = true;
      await controller.setZoomLevel(2);
      expect((await controller.getCameraZoomState())!['available'], isFalse);
      expect(controller.cameraError, isNull);
      expect(await controller.captureDeliveryPhoto(), isNotNull);
    },
  );

  test(
    'native camera interruption is surfaced and manual reopen recovers',
    () async {
      await initialize();
      platform.errors.add(CameraErrorEvent(1, 'camera disconnected'));
      await flush();
      expect(controller.cameraError, 'camera disconnected');
      await initialize();
      expect(controller.cameraError, isNull);
      expect(controller.camera!.cameraId, 2);
      platform.emit();
      await flush();
      expect(frames.single['analysisMode'], 'detect');
    },
  );
}

class _Detector extends PicoDetDetector {
  _Detector() : super(_model);
  Completer<void>? openGate;
  bool failOpen = false, failDetect = false;
  int closes = 0, inferences = 0;
  @override
  Future<void> open() async {
    await openGate?.future;
    if (failOpen) throw StateError('模拟模型加载失败');
  }

  @override
  Future<List<SceneObject>> detect(Float32List input, double confidence) async {
    inferences++;
    if (failDetect) throw StateError('模拟推理失败');
    return [];
  }

  @override
  Future<void> close() async => closes++;
}

/// 在实际 CameraController 下模拟厂商相机能力、系统事件和异步初始化。
class _Camera extends CameraPlatform {
  _Camera(this.temp);
  final Directory temp;
  final errors = StreamController<CameraErrorEvent>.broadcast();
  final streams = <int, StreamController<CameraImageData>>{};
  final disposedIds = <int>[];
  Completer<void>? initializationGate;
  bool unsupportedControls = false, failStream = false, paused = false;
  int nextId = 0, streamStarts = 0;
  void optionalControl() {
    if (unsupportedControls) throw CameraException('unsupported', '模拟不支持的能力');
  }

  void emit() => streams[nextId]!.add(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      planes: [CameraImagePlane(bytes: Uint8List(6), bytesPerRow: 2)],
      height: 2,
      width: 2,
    ),
  );
  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
      lensType: CameraLensType.wide,
    ),
  ];
  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? preset, {
    bool enableAudio = false,
  }) async => ++nextId;
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async => initializationGate?.future;
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          1280,
          720,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      errors.stream.where((event) => event.cameraId == cameraId);
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async => optionalControl();
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async =>
      optionalControl();
  @override
  Future<double> getMinZoomLevel(int cameraId) async {
    optionalControl();
    return 1;
  }

  @override
  Future<double> getMaxZoomLevel(int cameraId) async {
    optionalControl();
    return 4;
  }

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async =>
      optionalControl();
  @override
  Future<void> pausePreview(int cameraId) async => paused = true;
  @override
  Future<void> resumePreview(int cameraId) async => paused = false;
  @override
  Future<void> dispose(int cameraId) async => disposedIds.add(cameraId);
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    if (failStream) throw CameraException('stream_unavailable', '模拟图像流失败');
    streamStarts++;
    return (streams[cameraId] ??= StreamController<CameraImageData>.broadcast())
        .stream;
  }

  @override
  bool supportsImageStreaming() => true;
  @override
  Future<XFile> takePicture(int cameraId) async {
    final file = File('${temp.path}/camera.jpg');
    await file.writeAsBytes([1, 2, 3]);
    return XFile(file.path);
  }
}
