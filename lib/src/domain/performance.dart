import 'dart:math' as math;

enum AnalysisTier { standard, reduced, lowFrequency, minimal }

class AnalysisBudget {
  const AnalysisBudget(
    this.tier,
    this.fps,
    this.framingIntervalMs,
    this.textEnabled,
  );
  final AnalysisTier tier;
  final int fps, framingIntervalMs;
  final bool textEnabled;
  bool get detectionEnabled => tier != AnalysisTier.minimal;
  bool get framingEnabled => framingIntervalMs > 0;
  String get label => switch (tier) {
    AnalysisTier.standard => '自动适配',
    AnalysisTier.reduced => '流畅优先',
    AnalysisTier.lowFrequency => '低频识别',
    AnalysisTier.minimal => '轻量提示',
  };
  Map<String, Object> toJson() => {
    'tier': tier.name,
    'inferenceFps': fps,
    'framingIntervalMs': framingIntervalMs,
    'textEnabled': textEnabled,
    'detectionEnabled': detectionEnabled,
  };
}

/// Downgrades are sticky for one camera session so cooling/recovery cannot make the UI and workload oscillate.
class PerformanceGovernor {
  PerformanceGovernor({this.requestedFps = 3});
  final int requestedFps;
  AnalysisTier _tier = AnalysisTier.standard;
  bool preferSmooth = false;
  bool _framingTooSlow = false;
  int _slowModel = 0, _verySlowModel = 0, _slowFraming = 0;
  final List<bool> _jank = [];
  final List<Map<String, Object>> changes = [];
  String reason = 'initial';

  AnalysisBudget get budget {
    final tier = preferSmooth && _tier == AnalysisTier.standard
        ? AnalysisTier.reduced
        : _tier;
    return switch (tier) {
      AnalysisTier.standard => AnalysisBudget(
        tier,
        requestedFps.clamp(1, 5),
        _framingTooSlow ? 0 : 800,
        true,
      ),
      AnalysisTier.reduced => AnalysisBudget(
        tier,
        math.min(requestedFps, 2).clamp(1, 2),
        _framingTooSlow ? 0 : 1200,
        false,
      ),
      AnalysisTier.lowFrequency => AnalysisBudget(tier, 1, 0, false),
      AnalysisTier.minimal => AnalysisBudget(tier, 1, 0, false),
    };
  }

  void _degrade(AnalysisTier tier, String why, int nowMs) {
    if (tier.index <= _tier.index) return;
    _tier = tier;
    reason = why;
    changes.add({'atMs': nowMs, 'reason': why, ...budget.toJson()});
  }

  void observeDevice(Map<dynamic, dynamic> state, int nowMs) {
    final thermal = (state['thermalLevel'] as num?)?.toInt() ?? 0;
    if (thermal >= 2) {
      _degrade(AnalysisTier.minimal, 'thermal_serious', nowMs);
    } else if (thermal == 1 ||
        state['lowPower'] == true ||
        state['lowRam'] == true) {
      _degrade(
        AnalysisTier.reduced,
        thermal == 1
            ? 'thermal_fair'
            : state['lowPower'] == true
            ? 'low_power'
            : 'low_ram',
        nowMs,
      );
    }
  }

  void observeModel(double ms, int nowMs) {
    if (!ms.isFinite || ms <= 0) return;
    _slowModel = ms > 180 ? _slowModel + 1 : 0;
    _verySlowModel = ms > 450 ? _verySlowModel + 1 : 0;
    if (_verySlowModel >= 4) {
      _degrade(AnalysisTier.lowFrequency, 'model_over_budget', nowMs);
    } else if (_slowModel >= 6) {
      _degrade(AnalysisTier.reduced, 'model_slow', nowMs);
    }
  }

  void observeFraming(double ms, int nowMs) {
    if (!ms.isFinite || ms <= 0) return;
    _slowFraming = ms > 450 ? _slowFraming + 1 : 0;
    if (_slowFraming >= 3 && !_framingTooSlow) {
      _framingTooSlow = true;
      reason = 'framing_over_budget';
      changes.add({'atMs': nowMs, 'reason': reason, ...budget.toJson()});
    }
  }

  void observeUiFrame(double workMs, int nowMs) {
    if (nowMs < 3000 || !workMs.isFinite) return;
    _jank.add(workMs > 40);
    if (_jank.length > 24) _jank.removeAt(0);
    if (_jank.length == 24 && _jank.where((v) => v).length >= 8) {
      _degrade(AnalysisTier.reduced, 'flutter_ui_jank', nowMs);
      _jank.clear();
    }
  }

  void memoryPressure(int nowMs) =>
      _degrade(AnalysisTier.minimal, 'memory_pressure', nowMs);
  Map<String, Object> toJson() => {
    ...budget.toJson(),
    'reason': reason,
    'changes': changes.map((entry) => Map<String, Object>.of(entry)).toList(),
    'scope':
        'sampling limits; no camera preview FPS or zero-latency guarantee; model remains loaded',
  };
}
