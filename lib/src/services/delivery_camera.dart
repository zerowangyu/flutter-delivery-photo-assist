import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/guidance.dart';
import 'picodet_model.dart';
import 'frame_tensor.dart';

const deliveryNative = MethodChannel('delivery_photo_assist');

class CameraAnalysisConfig {
  const CameraAnalysisConfig(this.fps);
  final int fps;
}

/// 相机与识别独立：相机成功打开后，即使模型失败也可拍照。
class DeliveryCameraController {
  DeliveryCameraController({
    PicoDetDetector Function(PicoDetModel)? detectorFactory,
  }) : _detectorFactory = detectorFactory ?? PicoDetDetector.new;

  final PicoDetDetector Function(PicoDetModel) _detectorFactory;
  CameraController? _camera;
  PicoDetDetector? _detector;
  PicoDetModel? _model;
  Future<void> _initialization = Future<void>.value();
  Future<void> _previewOperations = Future<void>.value();
  int _initializationEpoch = 0;
  bool _wantsActive = true, _streamReady = false, _zoomAvailable = false;
  final changes = ValueNotifier<int>(0);
  final _zoomEvents = StreamController<double>.broadcast();
  Stream<double> get zoomEvents => _zoomEvents.stream;
  bool _disposed = false, _active = false, _busy = false, _captureBusy = false;
  bool _detection = true, _textEnabled = true, _textBusy = false;
  bool showBoxes = false, isTorchEnabled = false;
  double _confidence = .35, _zoom = 1, _minimum = 1, _maximum = 1;
  int _fps = 3, _frameNumber = 0, _generation = 0;
  int _lastFrame = -10000, _lastText = -10000, _textInterval = 2000;
  int _jpegAt = -10000, _textFrameAt = -10000;
  final _clock = Stopwatch()..start();
  Uint8List? _jpeg;
  Map<dynamic, dynamic>? _quality;
  Map<dynamic, dynamic> _text = {};
  List<SceneObject> objects = [];
  Size frameSize = const Size(720, 1280);
  String? cameraError;
  String? modelError;
  VoidCallback? _onReady;
  void Function(Map<String, dynamic>)? _onFrame;
  void Function(String)? _onError;
  bool get isInitialized =>
      !_disposed && (_camera?.value.isInitialized ?? false);
  CameraController? get camera => _camera;
  bool get modelReady => !_disposed && _detector != null;

  bool _current(int epoch, [CameraController? camera]) =>
      !_disposed &&
      epoch == _initializationEpoch &&
      (camera == null || identical(camera, _camera));

  Future<void> initialize(
    PicoDetModel model, {
    required void Function(Map<String, dynamic>) onFrame,
    required void Function(String) onError,
    required VoidCallback onReady,
  }) {
    if (_disposed) return Future<void>.value();
    final epoch = ++_initializationEpoch;
    _model = model;
    _onFrame = onFrame;
    _onError = onError;
    _onReady = onReady;
    _active = false;
    _generation++;
    // 重开请求串行清理资源；迟到的旧初始化不能覆盖新相机或模型。
    return _initialization = _initialization.then(
      (_) => _initialize(model, epoch),
    );
  }

  Future<void> _initialize(PicoDetModel model, int epoch) async {
    if (!_current(epoch)) return;
    await _previewOperations;
    final previous = _camera;
    _camera = null;
    final previousDetector = _detector;
    _detector = null;
    _streamReady = false;
    _zoomAvailable = false;
    await _optional(() async => previous?.dispose());
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _optional(() async => previousDetector?.close());
    if (!_current(epoch)) return;
    cameraError = null;
    modelError = null;
    objects = [];
    _jpeg = null;
    _text = {};
    isTorchEnabled = false;
    try {
      final cameras = await availableCameras();
      final back = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();
      if (back.isEmpty) throw StateError('没有可用的后置相机');
      final description = back.firstWhere(
        (c) => c.lensType == CameraLensType.wide,
        orElse: () => back.first,
      );
      if (!_current(epoch)) return;
      final next = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      _camera = next;
      next.addListener(() {
        if (_current(epoch, next) &&
            next.value.hasError &&
            cameraError != next.value.errorDescription) {
          cameraError = next.value.errorDescription;
          _active = false;
          _onError?.call('相机暂不可用，请重新打开');
          _notify();
        }
      });
      await next.initialize();
      if (!_current(epoch, next)) return;
      // 缩放、方向锁定和补光并非所有设备都支持，失败不应关闭快门或识别。
      await _optional(
        () => next.lockCaptureOrientation(DeviceOrientation.portraitUp),
      );
      _minimum = _maximum = _zoom = 1;
      try {
        final low = await next.getMinZoomLevel();
        final high = math.min(8.0, await next.getMaxZoomLevel());
        if (!low.isFinite || !high.isFinite || low <= 0 || high < low) {
          throw StateError('无效的缩放范围');
        }
        final zoom = 1.0.clamp(low, high);
        await next.setZoomLevel(zoom);
        if (!_current(epoch, next)) return;
        _minimum = low;
        _maximum = high;
        _zoom = zoom;
        _zoomAvailable = high > low;
      } catch (_) {
        _zoomAvailable = false;
      }
      if (!_current(epoch, next)) return;
      await _optional(() => next.setFlashMode(FlashMode.off));
      await _syncPreview(next, model, epoch);
      if (!_current(epoch, next)) return;
      _notify();
      _onReady?.call();
      // 模型加载不会推迟相机预览或快门可用时机。
      final detector = _detectorFactory(model);
      try {
        await detector.open();
        if (!_current(epoch, next)) {
          await detector.close();
          return;
        }
        _detector = detector;
      } catch (error) {
        await _optional(detector.close);
        if (!_current(epoch, next)) return;
        modelError = error.toString();
        _onError?.call('识别暂不可用，仍可拍照');
      }
      if (!_current(epoch, next)) return;
      _streamReady = true;
      _notify();
      await _syncPreview(next, model, epoch);
    } catch (error) {
      if (!_current(epoch)) return;
      cameraError = error.toString();
      _onError?.call('相机暂不可用，请重新打开');
      _notify();
    }
  }

  static Future<void> _optional(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // 可选相机功能或已被系统释放的旧资源，不影响正常拍照。
    }
  }

  Future<void> _syncPreview(
    CameraController camera,
    PicoDetModel model,
    int epoch,
  ) => _previewOperations = _previewOperations.then((_) async {
    if (!_current(epoch, camera) || !camera.value.isInitialized) return;
    if (!_wantsActive) {
      await _optional(() => camera.setFlashMode(FlashMode.off));
      isTorchEnabled = false;
      if (_current(epoch, camera)) await _optional(camera.pausePreview);
      return;
    }
    try {
      if (camera.value.isPreviewPaused) await camera.resumePreview();
      if (!_current(epoch, camera) || !_wantsActive) return;
      _active = true;
    } catch (error) {
      if (!_current(epoch, camera)) return;
      cameraError = error.toString();
      _active = false;
      _onError?.call('相机暂不可用，请重新打开');
      _notify();
      return;
    }
    if (!_streamReady || camera.value.isStreamingImages) return;
    try {
      await camera.startImageStream((image) {
        if (_current(epoch, camera)) _accept(image, model);
      });
    } catch (error) {
      if (!_current(epoch, camera)) return;
      modelError = error.toString();
      _onError?.call('识别暂不可用，仍可拍照');
      _notify();
    }
  });

  void _notify() {
    if (!_disposed) changes.value++;
  }

  Future<void> setThresholds({
    required double confidenceThreshold,
    int numItemsThreshold = 20,
  }) async {
    _confidence = confidenceThreshold;
  }

  Future<void> setShowOverlays(bool value) async {
    showBoxes = value;
    _notify();
  }

  Future<void> setStreamingConfig(CameraAnalysisConfig config) async {
    _fps = config.fps.clamp(1, 5);
  }

  Future<void> setDeliveryAnalysisPolicy({
    required bool detectionEnabled,
    required bool textEnabled,
    required int textIntervalMs,
  }) async {
    _detection = detectionEnabled;
    _textEnabled = textEnabled;
    _textInterval = math.max(2000, textIntervalMs);
    if (!textEnabled) _text = {};
  }

  Future<Map<String, dynamic>?> getCameraZoomState() async => !isInitialized
      ? null
      : {
          'available': _zoomAvailable,
          'minimum': _minimum,
          'maximum': _maximum,
          'current': _zoom,
        };
  Future<void> setZoomLevel(double value) async {
    final camera = _camera;
    if (!isInitialized || !_active || !_zoomAvailable || !value.isFinite)
      return;
    final epoch = _initializationEpoch;
    _generation++;
    _jpeg = null;
    objects = [];
    _text = {};
    final target = value.clamp(_minimum, _maximum);
    try {
      await camera!.setZoomLevel(target);
    } catch (_) {
      if (_current(epoch, camera)) {
        _zoomAvailable = false;
        _onError?.call('当前相机暂不支持缩放，仍可拍照');
        _notify();
      }
      return;
    }
    if (!_current(epoch, camera)) return;
    _zoom = target;
    if (!_disposed) _zoomEvents.add(target);
    _notify();
  }

  void resetTorchState() {
    isTorchEnabled = false;
  }

  Future<void> toggleTorch() async {
    if (!isInitialized || !_active) return;
    final camera = _camera!;
    final epoch = _initializationEpoch;
    final next = !isTorchEnabled;
    try {
      await camera.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (_current(epoch, camera) && _active) isTorchEnabled = next;
    } catch (_) {
      if (_current(epoch, camera)) _onError?.call('当前相机暂不支持补光灯');
    }
  }

  Future<Map<String, dynamic>?> getCameraPerformanceState() =>
      deliveryNative.invokeMapMethod<String, dynamic>('performanceState');

  void _accept(CameraImage image, PicoDetModel model) {
    final now = _clock.elapsedMilliseconds;
    if (_disposed ||
        !_active ||
        _busy ||
        _captureBusy ||
        now - _lastFrame < 1000 / _fps)
      return;
    _lastFrame = now;
    _busy = true;
    unawaited(_analyze(image, model, now).whenComplete(() => _busy = false));
  }

  Future<void> _analyze(
    CameraImage image,
    PicoDetModel model,
    int started,
  ) async {
    final generation = _generation;
    try {
      final parcel = objects
          .where((o) => parcelLabels.contains(o.label))
          .firstOrNull;
      final rotation = image.width > image.height
          ? _camera!.description.sensorOrientation
          : 0;
      final packet = await deliveryNative.invokeMapMethod<dynamic, dynamic>(
        'prepareCameraFrame',
        {
          'width': image.width,
          'height': image.height,
          'format': image.format.group.name,
          'rotation': rotation,
          'inputSize': model.inputSize,
          if (model.iosInterpolation != null)
            'iosInterpolation': model.iosInterpolation,
          'planes': image.planes
              .map(
                (p) => {
                  'bytes': p.bytes,
                  'rowStride': p.bytesPerRow,
                  'pixelStride': p.bytesPerPixel ?? 1,
                },
              )
              .toList(),
          'packageBox': parcel?.toJson()['box'],
          'prepareTensor': _detection && _detector != null,
        },
      );
      if (_disposed || !_active || generation != _generation || packet == null)
        return;
      final data = packet['tensor'] as Uint8List?;
      var detections = <SceneObject>[];
      final inferenceClock = Stopwatch()..start();
      if (_detection && _detector != null && data != null) {
        detections = await _detector!.detect(frameTensor(data), _confidence);
        if (!_disposed && _active && generation == _generation) {
          if (modelError != null) {
            modelError = null;
            _notify();
          }
        }
      }
      final inferenceMs = inferenceClock.elapsedMicroseconds / 1000;
      if (_disposed || !_active || generation != _generation || _captureBusy)
        return;
      _jpeg = packet['jpeg'] as Uint8List?;
      _jpegAt = started;
      _quality = packet['quality'] as Map?;
      frameSize = Size(
        (packet['width'] as num).toDouble(),
        (packet['height'] as num).toDouble(),
      );
      objects = detections;
      if (showBoxes) _notify();
      if (_textEnabled &&
          !_textBusy &&
          _jpeg != null &&
          started - _lastText >= _textInterval) {
        _textBusy = true;
        _lastText = started;
        _text = {};
        final jpeg = _jpeg!;
        unawaited(
          deliveryNative
              .invokeMapMethod<dynamic, dynamic>('analyzeSceneText', {
                'image': jpeg,
              })
              .then((result) {
                if (!_disposed && generation == _generation && _textEnabled)
                  _text = result ?? {};
                _textFrameAt = started;
              })
              .catchError((Object _) {})
              .whenComplete(() => _textBusy = false),
        );
      }
      _onFrame?.call({
        'frameNumber': ++_frameNumber,
        'detections': objects.map((o) => o.toJson()).toList(),
        'imageWidth': frameSize.width,
        'imageHeight': frameSize.height,
        'processingTimeMs': (_clock.elapsedMilliseconds - started).toDouble(),
        'modelInferenceMs': inferenceMs,
        'analysisAgeMs': _clock.elapsedMilliseconds - started,
        'frameQuality': _quality,
        'sceneText':
            _textEnabled && _clock.elapsedMilliseconds - _textFrameAt <= 1500
            ? {..._text, 'ageMs': _clock.elapsedMilliseconds - _textFrameAt}
            : {},
        'analysisMode': _detection && _detector != null
            ? 'detect'
            : 'quality_only',
      });
    } catch (error) {
      if (!_disposed && _active && generation == _generation) {
        final changed = modelError != error.toString();
        modelError = error.toString();
        if (changed) _onError?.call('识别暂不可用，仍可拍照');
        _notify();
      }
    }
  }

  Future<Uint8List?> captureAnalysisFrame() async =>
      _clock.elapsedMilliseconds - _jpegAt <= 1200 ? _jpeg : null;

  Future<Map<String, dynamic>?> captureDeliveryPhoto({
    List<double>? packageBox,
    double? previewAspect,
  }) async {
    if (!isInitialized || _captureBusy) return null;
    final reference = _clock.elapsedMilliseconds - _jpegAt <= 1200
        ? _jpeg
        : null;
    final quality = _clock.elapsedMilliseconds - _jpegAt <= 1200
        ? _quality
        : null;
    _captureBusy = true;
    _generation++;
    try {
      final shot = await _camera!.takePicture();
      final jpeg = await shot.readAsBytes();
      await File(shot.path).delete();
      return {
        'jpeg': jpeg,
        'source': 'camera_photo',
        'quality': quality,
        'analysisReference': reference,
        'referenceScope': 'live_preview_at_shutter',
      };
    } finally {
      _captureBusy = false;
    }
  }

  Future<void> pause() async {
    _wantsActive = false;
    _active = false;
    _generation++;
    _jpeg = null;
    _text = {};
    objects = [];
    if (isInitialized && _model != null) {
      await _syncPreview(_camera!, _model!, _initializationEpoch);
    }
  }

  Future<void> resume() async {
    if (_disposed) return;
    _wantsActive = true;
    _generation++;
    if (isInitialized && _model != null) {
      await _syncPreview(_camera!, _model!, _initializationEpoch);
    }
  }

  Future<void> stop() => pause();
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _initializationEpoch++;
    _wantsActive = false;
    _active = false;
    _generation++;
    // 等初始化与当前推理释放资源后再关闭，避免加载/推理期间释放 session。
    unawaited(() async {
      await _initialization;
      await _previewOperations;
      final camera = _camera;
      _camera = null;
      await _optional(() async => camera?.dispose());
      while (_busy) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final detector = _detector;
      _detector = null;
      await _optional(() async => detector?.close());
    }());
    unawaited(_zoomEvents.close());
    changes.dispose();
  }
}

class DeliveryCameraView extends StatefulWidget {
  const DeliveryCameraView({
    super.key,
    required this.controller,
    required this.model,
    required this.onFrame,
    required this.onError,
  });
  final DeliveryCameraController controller;
  final PicoDetModel model;
  final void Function(Map<String, dynamic>) onFrame;
  final void Function(String) onError;
  @override
  State<DeliveryCameraView> createState() => _DeliveryCameraViewState();
}

class _DeliveryCameraViewState extends State<DeliveryCameraView> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.controller.initialize(
        widget.model,
        onFrame: widget.onFrame,
        onError: widget.onError,
        onReady: () {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: widget.controller.changes,
    builder: (_, _, _) {
      final camera = widget.controller.camera;
      if (camera == null || !widget.controller.isInitialized) {
        return const ColoredBox(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(color: Colors.white54),
          ),
        );
      }
      final preview = camera.value.previewSize!;
      return ClipRect(
        child: LayoutBuilder(
          builder: (_, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: preview.height,
                  height: preview.width,
                  child: CameraPreview(camera),
                ),
              ),
              if (widget.controller.showBoxes)
                IgnorePointer(
                  child: CustomPaint(
                    painter: _ObjectPainter(
                      widget.controller.objects,
                      widget.controller.frameSize,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _ObjectPainter extends CustomPainter {
  _ObjectPainter(this.objects, this.frame);
  final List<SceneObject> objects;
  final Size frame;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.max(
      size.width / frame.width,
      size.height / frame.height,
    );
    final offset = Offset(
      (size.width - frame.width * scale) / 2,
      (size.height - frame.height * scale) / 2,
    );
    final paint = Paint()
      ..color = const Color(0xFFE8D798)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final object in objects) {
      final r = object.clipped;
      final box = Rect.fromLTRB(
        r.left * frame.width * scale + offset.dx,
        r.top * frame.height * scale + offset.dy,
        r.right * frame.width * scale + offset.dx,
        r.bottom * frame.height * scale + offset.dy,
      );
      canvas.drawRect(box, paint);
      final label = TextPainter(
        text: TextSpan(
          text: object.displayName,
          style: const TextStyle(
            color: Colors.white,
            backgroundColor: Colors.black54,
            fontSize: 11,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      label.paint(
        canvas,
        Offset(
          box.left.clamp(0, math.max(0, size.width - label.width)),
          math.max(0, box.top - label.height),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_ObjectPainter oldDelegate) => true;
}
