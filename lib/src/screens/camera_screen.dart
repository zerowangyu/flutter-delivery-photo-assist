import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import '../services/delivery_camera.dart';
import '../services/picodet_model.dart';
import '../domain/guidance.dart';
import '../domain/clarity.dart';
import '../domain/scene_text.dart';
import '../domain/capture_guidance.dart';
import '../domain/framing.dart';
import '../services/framing_service.dart';
import '../domain/performance.dart';
import '../widgets/camera_chrome.dart';
import '../services/gallery_import.dart';
import '../widgets/camera_controls.dart';

import '../services/session_store.dart';
import 'review_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    required this.model,
    this.returnWhenComplete = false,
    required this.session,
    required this.settings,
  });
  final PicoDetModel model;
  final bool returnWhenComplete;
  final PhotoSession session;
  final GuideSettings settings;
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final _controller = DeliveryCameraController();
  final _clock = Stopwatch()..start();
  final _timings = TimingSummary();
  final _callbacks = TimingSummary();
  final _rules = const GuidanceRules();
  final _store = SessionStore();
  late final HintStabilizer _stabilizer;
  late final Timer _ticker;
  late final Timer _framingTimer;
  FramingService? _framing;
  final _framingTracker = FramingTracker();
  bool _framingBusy = false;
  bool _referenceReady = false;
  int _analysisGeneration = 0;
  String? _framingError;
  ShotStage _stage = ShotStage.parcel;
  SceneFacts? _facts;
  GuideHint _hint = GuideHint.waiting;
  bool _capturing = false;
  bool _debug = false;
  bool _importing = false;
  bool _torch = false;
  bool _active = true;
  bool _leaving = false;
  bool _boxes = false;
  bool _sawFrame = false;
  int? _lastFrameNumber;
  int _cameraGeneration = 0;
  double? _captureMs;
  double? _previewAspect;
  String? _error;
  StreamSubscription<double>? _zoomSubscription;
  Timer? _zoomTimer;
  bool _zoomAvailable = false;
  bool _zoomStateBusy = false;
  bool _zoomBusy = false;
  double _zoom = 1;
  double _minimumZoom = 1;
  double _maximumZoom = 1;
  double? _pendingZoom;
  int _lastZoomRefreshMs = -1000;
  int _lastZoomChangeMs = -1000;
  late final PerformanceGovernor _governor;
  final _ui = ValueNotifier<int>(0);
  late Widget _nativeView;
  String _uiSignature = '', _policyKey = '';
  bool _policyBusy = false, _deviceStateBusy = false;
  int _lastDevicePollMs = -5000, _lastFramingStartMs = -5000;
  int _lastDebugUiMs = 0;
  String? _notice;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    _stage = widget.session.retakeStage ?? ShotStage.parcel;
    WidgetsBinding.instance.addObserver(this);
    _stabilizer = HintStabilizer(requiredFrames: widget.settings.stableFrames);
    _boxes = widget.settings.showBoxes;
    _governor = PerformanceGovernor(requestedFps: widget.settings.inferenceFps);
    if (_stage == ShotStage.environment) unawaited(_restoreReference());
    _nativeView = _createNativeView();
    SchedulerBinding.instance.addTimingsCallback(_onUiTimings);
    unawaited(
      _controller.setThresholds(
        confidenceThreshold: widget.settings.confidence,
        numItemsThreshold: 20,
      ),
    );
    unawaited(_controller.setShowOverlays(_boxes));
    _zoomSubscription = _controller.zoomEvents.listen(_onZoomChanged);
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || !_active) return;
      _hint = _stabilizer.at(_clock.elapsedMilliseconds).forStage(_stage);
      _publishUi();
      final now = _clock.elapsedMilliseconds;
      if (now - _lastZoomRefreshMs >= (_zoomAvailable ? 3000 : 500)) {
        unawaited(_refreshZoomState());
      }
      if (now - _lastDevicePollMs >= 5000) unawaited(_pollDeviceState());
      unawaited(_syncAnalysisPolicy());
    });
    _framingTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(_pollFraming()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_leaving) {
        _analysisGeneration++;
        _framingTracker.reset(_framingTracker.referenceId);
        _active = true;
        _lastFrameNumber = null;
        _stabilizer.reset();
        _facts = null;
        unawaited(_controller.resume());
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _active = false;
      _zoomTimer?.cancel();
      _zoomTimer = null;
      _pendingZoom = null;
      _analysisGeneration++;
      _framingTracker.reset(_framingTracker.referenceId);
      _torch = false;
      _controller.resetTorchState();
      unawaited(_controller.pause());
    }
  }

  Future<void> _refreshZoomState() async {
    if (!mounted ||
        !_active ||
        _leaving ||
        _zoomStateBusy ||
        !_controller.isInitialized) {
      return;
    }
    _zoomStateBusy = true;
    _lastZoomRefreshMs = _clock.elapsedMilliseconds;
    try {
      final state = await _controller.getCameraZoomState();
      if (!mounted || !_active) return;
      if (state?['available'] != true) {
        if (_zoomAvailable) _update(() => _zoomAvailable = false);
        return;
      }
      final low = (state!['minimum'] as num?)?.toDouble();
      final high = (state['maximum'] as num?)?.toDouble();
      final current = (state['current'] as num?)?.toDouble();
      if (low == null ||
          high == null ||
          current == null ||
          !low.isFinite ||
          !high.isFinite ||
          !current.isFinite ||
          low <= 0 ||
          high < low) {
        return;
      }
      _update(() {
        _zoomAvailable = true;
        _minimumZoom = low;
        _maximumZoom = high;
      });
      _onZoomChanged(current);
    } finally {
      _zoomStateBusy = false;
    }
  }

  void _invalidateZoomAdvice() {
    _lastZoomChangeMs = _clock.elapsedMilliseconds;
    _analysisGeneration++;
    _framingTracker.reset(_framingTracker.referenceId);
    _stabilizer.reset();
    _facts = null;
    _hint = GuideHint.waiting.forStage(_stage);
  }

  void _onZoomChanged(double value) {
    if (!mounted || !_active || _leaving || !value.isFinite || value <= 0) {
      return;
    }
    if ((_zoom - value).abs() < .001) return;
    _update(() {
      _zoom = value;
      _invalidateZoomAdvice();
    });
  }

  void _requestZoom(double value) {
    if (!_zoomAvailable || _capturing || !_active || _leaving) return;
    if (!value.isFinite) return;
    _pendingZoom = value.clamp(_minimumZoom, _maximumZoom);
    _update(_invalidateZoomAdvice);
    // Coalesce rapid pinch updates; never queue every pointer movement on the camera.
    _zoomTimer ??= Timer(const Duration(milliseconds: 60), () {
      _zoomTimer = null;
      unawaited(_applyPendingZoom());
    });
  }

  Future<void> _applyPendingZoom() async {
    if (_zoomBusy || !mounted || !_active || _leaving) return;
    final target = _pendingZoom;
    if (target == null) return;
    _pendingZoom = null;
    _zoomBusy = true;
    try {
      await _controller.setZoomLevel(target);
    } finally {
      _zoomBusy = false;
      if (mounted && _active && !_leaving && _pendingZoom != null) {
        _zoomTimer ??= Timer(const Duration(milliseconds: 60), () {
          _zoomTimer = null;
          unawaited(_applyPendingZoom());
        });
      }
    }
  }

  void _onFrame(Map<String, dynamic> data) {
    if (!mounted || !_active || _leaving || !data.containsKey('detections')) {
      return;
    }
    final frameNumber = (data['frameNumber'] as num?)?.toInt();
    if (frameNumber != null &&
        frameNumber > 0 &&
        frameNumber == _lastFrameNumber) {
      return;
    }
    _lastFrameNumber = frameNumber;
    final objects = <SceneObject>[];
    for (final item in (data['detections'] as List<dynamic>? ?? [])) {
      if (item is! Map) continue;
      try {
        final box = List<num>.from(item['box'] as List);
        objects.add(
          SceneObject(
            item['label'] as String,
            (item['confidence'] as num).toDouble(),
            Rect.fromLTRB(
              box[0].toDouble(),
              box[1].toDouble(),
              box[2].toDouble(),
              box[3].toDouble(),
            ),
          ),
        );
      } catch (_) {
        /* Malformed detections must not break the camera. */
      }
    }
    final now = _clock.elapsedMilliseconds;
    final frameWidth = (data['imageWidth'] as num?)?.toDouble() ?? 0;
    final frameHeight = (data['imageHeight'] as num?)?.toDouble() ?? 0;
    if (frameWidth > 0 && frameHeight > 0) {
      _previewAspect = frameWidth / frameHeight;
    }
    final processing = (data['processingTimeMs'] as num?)?.toDouble() ?? 0;
    _callbacks.add(0, now);
    if (data['analysisMode'] != 'quality_only') {
      _timings.add(processing, now);
      _governor.observeModel(processing, now);
    }
    unawaited(_syncAnalysisPolicy());
    final rawQuality = FrameClarity.parse(data['frameQuality']);
    final facts = SceneFacts(
      objects: objects,
      receivedAtMs: now - ((data['analysisAgeMs'] as num?)?.toInt() ?? 0),
      processingMs: processing,
      clarity: _stage == ShotStage.environment
          ? rawQuality?.environmentOnly
          : rawQuality,
      textClues: SceneTextClues.parse(data['sceneText']),
    );
    final hint = _stabilizer
        .add(_rules.evaluate(facts, _stage, widget.settings), now)
        .forStage(_stage);
    _facts = facts;
    _hint = hint;
    _sawFrame = true;
    if (_controller.cameraError == null) _error = null;
    _publishUi();
  }

  void _switchStage(ShotStage stage) {
    if (_capturing || widget.session.retakeStage != null) return;
    if (stage == ShotStage.environment &&
        widget.session.shots[ShotStage.parcel] == null) {
      _message('请先拍第一张，再拍周围环境');
      return;
    }
    _stabilizer.reset();
    _analysisGeneration++;
    _framingTracker.reset(_framingTracker.referenceId);
    _update(() {
      _stage = stage;
      _hint = GuideHint.waiting.forStage(stage);
      _facts = null;
    });
  }

  CaptureAdvice _decision() {
    if (_capturing) {
      return CaptureAdvice(
        CaptureState.observing,
        _importing ? '正在导入照片' : '正在拍摄',
        '正在保存照片',
        'capturing',
      );
    }
    if (_error != null) {
      return CaptureAdvice(
        CaptureState.attention,
        _error!,
        '请重新打开相机',
        'camera_error',
      );
    }
    if (_controller.modelError != null) {
      return const CaptureAdvice(
        CaptureState.observing,
        '识别暂不可用，仍可拍照',
        '请自行确认包裹与位置清晰，可在设置中重新打开相机',
        'recognition_error',
      );
    }
    if (_clock.elapsedMilliseconds - _lastZoomChangeMs < 250) {
      return const CaptureAdvice(
        CaptureState.observing,
        '正在调整取景',
        '提示更新中，仍可直接拍照',
        'zoom_changing',
      );
    }
    final freshFacts =
        _facts != null &&
            _clock.elapsedMilliseconds - _facts!.receivedAtMs <= 1200
        ? _facts
        : null;
    if ((!_governor.budget.detectionEnabled ||
            !_governor.budget.framingEnabled) &&
        (freshFacts?.clarity?.needsRetake == true ||
            freshFacts?.clarity?.state == ClarityState.focusing)) {
      return const CaptureGuidance().evaluate(
        stage: _stage,
        facts: freshFacts,
        settings: widget.settings,
        nowMs: _clock.elapsedMilliseconds,
        stable: false,
        framing: _framingTracker,
      );
    }
    if (!_governor.budget.detectionEnabled) {
      return const CaptureAdvice(
        CaptureState.observing,
        '请确认包裹与位置能看清',
        '已切换轻量提示，可直接拍照',
        'lightweight_mode',
      );
    }
    if (_stage == ShotStage.environment && !_governor.budget.framingEnabled) {
      return const CaptureAdvice(
        CaptureState.observing,
        '请对照第一张，拍入更多环境',
        '远景比较已暂停，仍可直接拍照',
        'framing_paused',
      );
    }
    if (_stage == ShotStage.environment) {
      if (_framingError != null) {
        return const CaptureAdvice(
          CaptureState.observing,
          '远景参考暂不可用',
          '仍可直接拍照，提示仅供参考',
          'framing_error',
        );
      }
      if (!_referenceReady) {
        return const CaptureAdvice(
          CaptureState.observing,
          '正在准备第一张参考',
          '可后退扩大取景，也可直接拍照',
          'reference_loading',
        );
      }
    }
    final facts = _facts;
    return const CaptureGuidance().evaluate(
      stage: _stage,
      facts: facts,
      settings: widget.settings,
      nowMs: _clock.elapsedMilliseconds,
      stable:
          facts != null &&
          _hint.code == _rules.evaluate(facts, _stage, widget.settings).code,
      framing: _framingTracker,
    );
  }

  Future<void> _pollFraming() async {
    if (!mounted ||
        !_active ||
        _leaving ||
        _capturing ||
        _framingBusy ||
        !_governor.budget.framingEnabled ||
        _framing == null ||
        _clock.elapsedMilliseconds - _lastFramingStartMs <
            _governor.budget.framingIntervalMs ||
        _clock.elapsedMilliseconds - _lastZoomChangeMs < 250 ||
        !_referenceReady ||
        _stage != ShotStage.environment ||
        !_controller.isInitialized) {
      return;
    }
    _framingBusy = true;
    _lastFramingStartMs = _clock.elapsedMilliseconds;
    final generation = _analysisGeneration;
    final started = _clock.elapsedMilliseconds;
    try {
      final jpeg = await _controller.captureAnalysisFrame().timeout(
        const Duration(seconds: 3),
      );
      if (jpeg == null ||
          !mounted ||
          generation != _analysisGeneration ||
          !_active) {
        return;
      }
      final service = _framing;
      if (service == null) return;
      final check = await service.compare(jpeg);
      _governor.observeFraming(
        (_clock.elapsedMilliseconds - started).toDouble(),
        _clock.elapsedMilliseconds,
      );
      unawaited(_syncAnalysisPolicy());
      if (!mounted || generation != _analysisGeneration || !_active) return;
      _update(() {
        _framingTracker.add(check, started);
        _framingError = null;
      });
    } catch (error) {
      if (mounted && generation == _analysisGeneration && _active) {
        _update(() {
          _framingTracker.reset(_framingTracker.referenceId);
          _framingError = error.toString();
        });
      }
    } finally {
      _framingBusy = false;
    }
  }

  Future<void> _prepareReference(Uint8List jpeg, String id) async {
    if (!_governor.budget.framingEnabled) return;
    final service = _framing ??= FramingService();
    try {
      await service.setReference(jpeg, id);
      if (!mounted ||
          !identical(_framing, service) ||
          !_governor.budget.framingEnabled ||
          _framingTracker.referenceId != id) {
        return;
      }
      _update(() {
        _referenceReady = true;
        _framingError = null;
      });
    } catch (error) {
      if (mounted && _framingTracker.referenceId == id) {
        _update(() => _framingError = error.toString());
      }
    }
  }

  Future<void> _restoreReference() async {
    final first = widget.session.shots[ShotStage.parcel];
    if (first == null) return;
    final id = first.path.split(Platform.pathSeparator).last;
    _framingTracker.reset(id);
    final path = first.framingReferencePath;
    if (path == null) {
      _framingError = '第一张预览参考暂不可用';
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted || _leaving) return;
      await _prepareReference(bytes, id);
    } catch (_) {
      if (mounted && !_leaving) {
        _update(() => _framingError = '第一张预览参考暂不可用');
      }
    }
  }

  Future<void> _capture() async {
    if (_capturing || _leaving || !_active) return;
    if (!_controller.isInitialized) {
      _message('相机还在启动，请稍后重试');
      return;
    }
    final adviceAtTap = _decision();
    final tapClock = Stopwatch()..start();
    final stageAtTap = _stage;
    final factsAtTap = _facts;
    final sceneAge = factsAtTap == null
        ? null
        : _clock.elapsedMilliseconds - factsAtTap.receivedAtMs;
    final framingAtTap = _framingTracker.current;
    final zoomAtTap = _zoom;
    final boxesAtTap = _boxes;
    _zoomTimer?.cancel();
    _zoomTimer = null;
    _pendingZoom = null;
    _analysisGeneration++;
    _update(() => _capturing = true);
    unawaited(_syncAnalysisPolicy());
    try {
      final package =
          stageAtTap == ShotStage.parcel && sceneAge != null && sceneAge <= 1500
          ? factsAtTap?.package(widget.settings)?.clipped
          : null;
      // The shutter never waits for framing advice or uses it as an acceptance condition.
      final capture = await _controller
          .captureDeliveryPhoto(
            packageBox: package == null
                ? null
                : [package.left, package.top, package.right, package.bottom],
            previewAspect: _previewAspect,
          )
          .timeout(const Duration(seconds: 8));
      final bytes = capture?['jpeg'] as Uint8List?;
      if (bytes == null) throw StateError('相机未返回照片');
      final rawQuality = FrameClarity.parse(capture?['quality']);
      final quality = stageAtTap == ShotStage.environment
          ? rawQuality?.environmentOnly
          : rawQuality;
      final captureMs = tapClock.elapsedMicroseconds / 1000;
      final shot = await _store.save(
        session: widget.session,
        stage: stageAtTap,
        bytes: bytes,
        tapClock: tapClock,
        captureMs: captureMs,
        hint: adviceAtTap.title,
        sceneAgeMs: sceneAge,
        scene: sceneAge != null && sceneAge <= 1500 ? factsAtTap : null,
        timings: _timingReport(),
        quality: quality?.toJson(),
        captureSource: capture?['source'] as String?,
        framingReference: capture?['analysisReference'] as Uint8List?,
        guidance: {
          'scope':
              'live_advice_only; never blocks saving; no post-photo framing verification',
          'state': adviceAtTap.state.name,
          'reason': adviceAtTap.reason,
          'performance': _governor.toJson(),
          'cameraZoom': zoomAtTap,
          'overlaysShown': boxesAtTap,
          'referenceScope': capture?['referenceScope'],
          if (stageAtTap == ShotStage.environment)
            'framingAdvice': framingAtTap.toJson(),
        },
      );
      _afterSaved(
        shot,
        bytes,
        captureMs,
        framingReference: capture?['analysisReference'] as Uint8List?,
      );
    } catch (error) {
      if (mounted) _message('拍摄失败：$error');
    } finally {
      if (mounted) {
        _update(() => _capturing = false);
        unawaited(_syncAnalysisPolicy());
      }
    }
  }

  void _message(String text) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    _update(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _update(() => _notice = null);
    });
  }

  Future<void> _review() async {
    if (_capturing || widget.session.shots.isEmpty) return;
    _leaving = true;
    _active = false;
    _zoomTimer?.cancel();
    _zoomTimer = null;
    _pendingZoom = null;
    _analysisGeneration++;
    _framingTracker.reset(_framingTracker.referenceId);
    await _controller.pause();
    if (!mounted) return;
    await _store.writeReport(widget.session, _timingReport());
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewScreen(report: File(widget.session.reportPath)),
      ),
    );
    if (!mounted) return;
    _leaving = false;
    _active = true;
    _facts = null;
    _lastFrameNumber = null;
    _stabilizer.reset();
    await _controller.resume();
  }

  @override
  void dispose() {
    _leaving = true;
    _active = false;
    _ticker.cancel();
    _framingTimer.cancel();
    _zoomTimer?.cancel();
    unawaited(_zoomSubscription?.cancel());
    _analysisGeneration++;
    unawaited(_framing?.dispose());
    _noticeTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onUiTimings);
    _ui.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) {
    if (!mounted) return;
    change();
    _publishUi(force: true);
  }

  String get _qualityLabel {
    final facts = _facts;
    if (facts == null ||
        _clock.elapsedMilliseconds - facts.receivedAtMs > 1200) {
      return '待确认';
    }
    return facts.clarity?.label ?? '待确认';
  }

  void _publishUi({bool force = false}) {
    if (!mounted || _leaving) return;
    final advice = _decision();
    final now = _clock.elapsedMilliseconds;
    final debugTick = _debug && now - _lastDebugUiMs >= 1000;
    final signature =
        '${_stage.name}|${advice.state.name}|${advice.title}|${advice.detail}|'
        '$_capturing|$_importing|$_boxes|$_torch|${_zoom.toStringAsFixed(2)}|$_zoomAvailable|'
        '$_minimumZoom|$_maximumZoom|$_qualityLabel|${widget.session.shots.length}|'
        '${widget.session.shots[ShotStage.parcel]?.path}|$_notice|${_governor.budget.label}';
    if (!force && !debugTick && signature == _uiSignature) return;
    _uiSignature = signature;
    if (debugTick) _lastDebugUiMs = now;
    _ui.value++;
  }

  Map<String, Object> _timingReport() => {
    ..._timings.toJson(),
    'callbackFps': _callbacks.callbackFps,
    'resultWindowFrames': _callbacks.count,
    'adaptivePerformance': _governor.toJson(),
  };

  CameraAnalysisConfig _streamConfig(int fps) => CameraAnalysisConfig(fps);

  Widget _createNativeView() => DeliveryCameraView(
    key: ValueKey(_cameraGeneration),
    model: widget.model,
    controller: _controller,
    onFrame: _onFrame,
    onError: (error) {
      if (!mounted) return;
      if (_controller.cameraError != null) {
        _update(() => _error = error);
      } else {
        _message(error);
      }
    },
  );

  Future<void> _pollDeviceState() async {
    if (_deviceStateBusy ||
        !_controller.isInitialized ||
        !_active ||
        _leaving) {
      return;
    }
    _lastDevicePollMs = _clock.elapsedMilliseconds;
    _deviceStateBusy = true;
    try {
      final state = await _controller.getCameraPerformanceState();
      if (!mounted || !_active) return;
      if (state != null) {
        _governor.observeDevice(state, _clock.elapsedMilliseconds);
      }
      await _syncAnalysisPolicy();
      _publishUi();
    } finally {
      _deviceStateBusy = false;
    }
  }

  void _onUiTimings(List<FrameTiming> timings) {
    if (!mounted || !_active || _leaving) return;
    for (final frame in timings) {
      _governor.observeUiFrame(
        (frame.buildDuration + frame.rasterDuration).inMicroseconds / 1000,
        _clock.elapsedMilliseconds,
      );
    }
    unawaited(_syncAnalysisPolicy());
  }

  @override
  void didHaveMemoryPressure() {
    if (!_active || _leaving) return;
    _governor.memoryPressure(_clock.elapsedMilliseconds);
    _facts = null;
    unawaited(_syncAnalysisPolicy());
    _publishUi();
  }

  Future<void> _syncAnalysisPolicy() async {
    if (_policyBusy ||
        !mounted ||
        !_active ||
        _leaving ||
        !_controller.isInitialized) {
      return;
    }
    _policyBusy = true;
    try {
      while (mounted && _active && !_leaving) {
        final budget = _governor.budget;
        final capture = _capturing;
        final key =
            '${budget.tier}|${budget.fps}|${budget.textEnabled}|${budget.framingEnabled}|$capture';
        if (key == _policyKey) break;
        _analysisGeneration++;
        _framingTracker.reset(_framingTracker.referenceId);
        if (!budget.framingEnabled && _framing != null) {
          final old = _framing;
          _framing = null;
          _referenceReady = false;
          unawaited(old?.dispose());
        }
        await _controller.setStreamingConfig(
          _streamConfig(capture ? 1 : budget.fps),
        );
        await _controller.setDeliveryAnalysisPolicy(
          detectionEnabled: budget.detectionEnabled && !capture,
          textEnabled: budget.textEnabled && !capture,
          textIntervalMs: 2000,
        );
        _policyKey = key;
        _publishUi();
      }
    } finally {
      _policyBusy = false;
    }
  }

  void _afterSaved(
    CapturedShot shot,
    Uint8List bytes,
    double elapsedMs, {
    Uint8List? framingReference,
  }) {
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    _update(() {
      _captureMs = elapsedMs;
      _capturing = false;
    });
    if (widget.session.retakeStage != null) {
      _leaving = true;
      _active = false;
      Navigator.of(context).pop(true);
      return;
    }
    if (shot.stage == ShotStage.parcel) {
      _referenceReady = false;
      _framingError = null;
      final id = shot.path.split(Platform.pathSeparator).last;
      _framingTracker.reset(id);
      final reference =
          framingReference ?? (shot.captureSource == 'gallery' ? bytes : null);
      if (reference != null) {
        unawaited(_prepareReference(reference, id));
      } else {
        _framingError = '第一张预览参考暂不可用';
      }
      _switchStage(ShotStage.environment);
      _message('第一张已保存，可继续拍周围环境');
    } else {
      if (widget.returnWhenComplete) {
        _leaving = true;
        _active = false;
        Navigator.of(context).pop(true);
        return;
      }
      _message('两张已保存，可回看或重新拍摄');
    }
  }

  Future<void> _pickFromGallery() async {
    if (_capturing || _leaving || !_active) return;
    final stage = _stage;
    _update(() {
      _capturing = true;
      _importing = true;
    });
    unawaited(_syncAnalysisPolicy());
    try {
      final result = await GalleryImport().pick();
      if (!mounted || result == null) return;
      final jpeg = result['jpeg'] as Uint8List?;
      if (jpeg == null) throw StateError('无法读取选中的照片');
      final elapsed = (result['importProcessingMs'] as num?)?.toDouble() ?? 0;
      final shot = await _store.save(
        session: widget.session,
        stage: stage,
        bytes: jpeg,
        tapClock: Stopwatch()..start(),
        captureMs: elapsed,
        hint: '相册导入，请人工确认取景',
        sceneAgeMs: null,
        scene: null,
        timings: _timingReport(),
        quality: FrameClarity.parse(result['quality'])?.toJson(),
        captureSource: 'gallery',
        framingReference: stage == ShotStage.parcel ? jpeg : null,
        guidance: {
          'scope':
              'gallery import; no live scene evidence or post-photo framing verification',
          'state': 'observing',
          'reason': 'gallery_import',
          'timingScope':
              'selected-file read/normalize; not camera shutter latency',
          'performance': _governor.toJson(),
        },
      );
      _afterSaved(shot, jpeg, elapsed);
    } catch (_) {
      if (mounted) _message('暂时无法导入，请重新选择照片');
    } finally {
      if (mounted) {
        _update(() {
          _capturing = false;
          _importing = false;
        });
        unawaited(_syncAnalysisPolicy());
      }
    }
  }

  void _openReference() {
    final shot = widget.session.shots[ShotStage.parcel];
    if (shot == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            const ListTile(
              title: Text('第一张照片对照'),
              subtitle: Text('第二张多拍一些周围环境'),
            ),
            Expanded(
              child: InteractiveViewer(
                child: Image.file(File(shot.path), fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _showOptions() async {
    _debug = true;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .65,
        child: ValueListenableBuilder<int>(
          valueListenable: _ui,
          builder: (_, _, _) {
            final labels =
                _facts
                    ?.eligible(widget.settings)
                    .map((o) => o.displayName)
                    .toSet()
                    .join('、') ??
                '';
            final text =
                _facts?.textClues.lines
                    .map((l) => l.text)
                    .take(3)
                    .join(' · ') ??
                '';
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                const Text(
                  '相机设置',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SwitchListTile.adaptive(
                  key: const Key('camera-boxes-option'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示识别框'),
                  subtitle: const Text('仅显示识别参考，照片不带框'),
                  value: _boxes,
                  onChanged: (value) {
                    _update(() => _boxes = value);
                    unawaited(_controller.setShowOverlays(value));
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('流畅优先'),
                  subtitle: const Text('减少识别频率，暂停文字识别'),
                  value: _governor.preferSmooth,
                  onChanged: (value) {
                    _update(() => _governor.preferSmooth = value);
                    unawaited(_syncAnalysisPolicy());
                  },
                ),
                const Divider(height: 28),
                Text(
                  '当前：${_governor.budget.label}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  '设备较慢、发热或省电时会减少分析；提示仍仅供参考，任何状态都可拍照。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '包裹识别：${_controller.modelError != null
                      ? '暂不可用'
                      : !_governor.budget.detectionEnabled
                      ? '保护暂停'
                      : !_controller.modelReady || !_sawFrame
                      ? '正在准备'
                      : _governor.budget.tier == AnalysisTier.lowFrequency
                      ? '低频运行，每秒最多一次'
                      : '运行中'}',
                  style: const TextStyle(fontSize: 13, height: 1.7),
                ),
                Text(
                  '识别参考：${labels.isEmpty ? '暂未确认' : labels}',
                  style: const TextStyle(fontSize: 13, height: 1.7),
                ),
                Text(
                  '文字参考：${text.isEmpty ? '暂无或已暂停' : text}',
                  style: const TextStyle(fontSize: 13, height: 1.7),
                ),
                const SizedBox(height: 16),
                Text(
                  '分析上限 ${_governor.budget.fps} 次/秒 · 结果回调 ${_callbacks.callbackFps.toStringAsFixed(1)} 次/秒\n'
                  '单帧分析 P50 ${_timings.percentile(.5).toStringAsFixed(0)} ms · P95 ${_timings.percentile(.95).toStringAsFixed(0)} ms\n'
                  '远景 ${_framingTracker.current.processingMs.toStringAsFixed(0)} ms · 最近照片返回 ${_captureMs?.toStringAsFixed(0) ?? '—'} ms\n'
                  '这些数据不是相机预览帧率或完整提示延迟',
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.8,
                    color: Colors.black54,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _policyKey = '';
                    _zoomAvailable = false;
                    _analysisGeneration++;
                    _facts = null;
                    _sawFrame = false;
                    _stabilizer.reset();
                    _framingTracker.reset(_framingTracker.referenceId);
                    super.setState(() {
                      _cameraGeneration++;
                      _nativeView = _createNativeView();
                      _error = null;
                    });
                  },
                  child: const Text('重新打开相机'),
                ),
              ],
            );
          },
        ),
      ),
    );
    if (mounted) {
      _debug = false;
      _publishUi();
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _ui,
    child: _nativeView,
    builder: (context, _, native) => PopScope(
      canPop: !_capturing,
      child: Scaffold(
        backgroundColor: const Color(0xFF121516),
        body: Stack(
          children: [
            Positioned.fill(
              child: CameraZoomGesture(
                zoom: _zoom,
                minimum: _minimumZoom,
                maximum: _maximumZoom,
                onChanged: _zoomAvailable && !_capturing ? _requestZoom : null,
                child: native!,
              ),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: CameraChrome(
                  stage: _stage,
                  retakeStage: widget.session.retakeStage,
                  savedStages: widget.session.shots.keys.toSet(),
                  advice: _decision(),
                  capturing: _capturing,
                  boxes: _boxes,
                  torch: _torch,
                  zoom: _zoom,
                  minimumZoom: _minimumZoom,
                  maximumZoom: _maximumZoom,
                  zoomAvailable: _zoomAvailable,
                  qualityLabel: _qualityLabel,
                  performanceLabel: _governor.budget.label,
                  notice: _notice,
                  firstShot: widget.session.shots[ShotStage.parcel] == null
                      ? null
                      : FileImage(
                          File(widget.session.shots[ShotStage.parcel]!.path),
                        ),
                  onBack: () => Navigator.of(context).pop(),
                  onMore: _showOptions,
                  onBoxes: (value) {
                    _update(() => _boxes = value);
                    unawaited(_controller.setShowOverlays(value));
                  },
                  onStage: _switchStage,
                  onZoom: _requestZoom,
                  onCapture: _capture,
                  onReview: _review,
                  onGallery: _pickFromGallery,
                  onReference: _openReference,
                  onTorch: () async {
                    await _controller.toggleTorch();
                    if (mounted) {
                      _update(() => _torch = _controller.isTorchEnabled);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
