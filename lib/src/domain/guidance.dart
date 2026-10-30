import 'dart:math' as math;
import 'dart:ui';
import 'clarity.dart';
import 'scene_text.dart';

enum ShotStage {
  parcel('第一张', '包裹与放置位置', '拍清完整包裹，并保留能说明放置位置的周围特征'),
  environment('第二张', '周围环境', '多拍一些周围环境，让人能看出第一张的放置位置');

  const ShotStage(this.label, this.title, this.description);
  final String label;
  final String title;
  final String description;
}

class GuideSettings {
  const GuideSettings({
    this.confidence = .35,
    this.inferenceFps = 3,
    this.showBoxes = false,
    this.includeBagCandidates = true,
    this.stableFrames = 3,
  });

  final double confidence;
  final int inferenceFps;
  final bool showBoxes;
  final bool includeBagCandidates;
  final int stableFrames;

  GuideSettings copyWith({
    double? confidence,
    int? inferenceFps,
    bool? showBoxes,
    bool? includeBagCandidates,
    int? stableFrames,
  }) => GuideSettings(
    confidence: confidence ?? this.confidence,
    inferenceFps: inferenceFps ?? this.inferenceFps,
    showBoxes: showBoxes ?? this.showBoxes,
    includeBagCandidates: includeBagCandidates ?? this.includeBagCandidates,
    stableFrames: stableFrames ?? this.stableFrames,
  );

  Map<String, Object> toJson() => {
    'confidence': confidence,
    'inferenceFps': inferenceFps,
    'showBoxes': showBoxes,
    'includeBagCandidates': includeBagCandidates,
    'stableFrames': stableFrames,
  };
}

const boxLabels = {
  'delivery_item',
  'Box',
  'cardboard box',
  'parcel_box',
  'beverage_case',
  'beverage_multipack',
  'delivery_crate',
  'bulky_delivery_item',
};
const parcelLabels = {
  ...boxLabels,
  'Plastic bag',
  'Handbag',
  'Luggage and bags',
  'plastic bag',
  'shopping bag',
  'paper bag',
  'delivery package',
  'insulated delivery bag',
  'parcel_bag',
  'insulated_bag',
};
const fixedLabels = {
  'Door',
  'Building',
  'House',
  'Office building',
  'Porch',
  'Stairs',
  'Window',
  'Tree',
  'Street light',
  'Traffic sign',
  'Fire hydrant',
  'door',
  'front door',
  'glass door',
  'building entrance',
  'building',
  'house',
  'stairs',
  'window',
  'porch',
  'tree',
  'street sign',
  'mailbox',
  'fence',
};
const auxiliaryLabels = {
  'Flowerpot',
  'Bench',
  'Vehicle registration plate',
  'flowerpot',
  'license plate',
};
const labelTranslations = {
  'Box': '箱子',
  'Plastic bag': '塑料袋',
  'Handbag': '手提袋',
  'Luggage and bags': '袋装物品',
  'Door': '门',
  'Building': '建筑',
  'House': '住宅',
  'Office building': '办公楼',
  'Porch': '门廊',
  'Stairs': '台阶',
  'Window': '窗户',
  'Tree': '树',
  'Street light': '路灯',
  'Traffic sign': '路牌',
  'Fire hydrant': '消防栓',
  'Flowerpot': '花盆',
  'Bench': '长椅',
  'Vehicle registration plate': '车牌',
  'door': '门',
  'front door': '入户门',
  'glass door': '玻璃门',
  'building entrance': '入口',
  'building': '建筑',
  'house': '住宅',
  'stairs': '台阶',
  'window': '窗户',
  'porch': '门廊',
  'tree': '树',
  'street sign': '路牌',
  'mailbox': '信箱',
  'fence': '围栏',
  'flowerpot': '花盆',
  'license plate': '车牌',
  'parcel_box': '配送纸箱',
  'parcel_bag': '配送袋装物品',
  'insulated_bag': '保温袋',
  'beverage_case': '整箱饮料',
  'beverage_multipack': '成提饮料',
  'delivery_crate': '配送周转箱',
  'bulky_delivery_item': '大件配送物品',
  'backpack': '背包／衣物候选',
};

class SceneObject {
  const SceneObject(this.label, this.confidence, this.box);
  final String label;
  final double confidence;
  // Coordinates refer to the entire upright camera frame, normalized to 0..1.
  final Rect box;

  Rect get clipped => box.intersect(const Rect.fromLTWH(0, 0, 1, 1));
  double get area => math.max(0, clipped.width) * math.max(0, clipped.height);
  bool get isValid =>
      confidence.isFinite &&
      [box.left, box.top, box.right, box.bottom].every((n) => n.isFinite) &&
      box.width > 0 &&
      box.height > 0 &&
      area > 0;
  // Appearance subclasses overlap; do not present them as verified parcel identity.
  String get displayName =>
      parcelLabels.contains(label) ? '包裹候选' : labelTranslations[label] ?? label;
  bool get touchesEdge =>
      clipped.left < .015 ||
      clipped.top < .015 ||
      clipped.right > .985 ||
      clipped.bottom > .985;

  Map<String, Object> toJson() => {
    'label': label,
    'confidence': confidence,
    'box': [box.left, box.top, box.right, box.bottom],
  };
}

class SceneFacts {
  const SceneFacts({
    this.objects = const [],
    required this.receivedAtMs,
    this.processingMs = 0,
    this.clarity,
    this.textClues = const SceneTextClues(),
  });
  final List<SceneObject> objects;
  final int receivedAtMs;
  final double processingMs;
  final FrameClarity? clarity;
  final SceneTextClues textClues;

  List<SceneObject> eligible(GuideSettings settings) => objects
      .where((o) => o.isValid && o.confidence >= settings.confidence)
      .toList();

  SceneObject? package(GuideSettings settings) {
    final candidates =
        eligible(settings)
            .where(
              (o) =>
                  boxLabels.contains(o.label) ||
                  (settings.includeBagCandidates &&
                      parcelLabels.contains(o.label)),
            )
            .toList()
          ..sort((a, b) => b.area.compareTo(a.area));
    return candidates.firstOrNull;
  }

  List<SceneObject> anchors(
    GuideSettings settings,
  ) => eligible(settings).where((o) {
    if (!fixedLabels.contains(o.label) || o.area < .005) return false;
    // A whole-frame building prediction can occur indoors; it cannot locate an entrance.
    if ({
          'Building',
          'Office building',
          'House',
          'building',
          'house',
        }.contains(o.label) &&
        o.area > .85) {
      return false;
    }
    return true;
  }).toList();

  Map<String, Object> toJson() => {
    'receivedAtMs': receivedAtMs,
    'processingMs': processingMs,
    'objects': objects.map((o) => o.toJson()).toList(),
    'clarity': clarity?.toJson() ?? {},
    'textClues': textClues.toJson(),
  };
}

enum HintCode {
  waiting,
  stale,
  packageMissing,
  closer,
  wider,
  contextUncertain,
  ready,
  blurry,
  dark,
  glare,
  focusing,
}

class GuideHint {
  const GuideHint(this.code, this.title, this.detail);
  final HintCode code;
  final String title;
  final String detail;
  GuideHint forStage(ShotStage stage) {
    if (stage != ShotStage.environment) return this;
    if (code == HintCode.waiting) {
      return const GuideHint(
        HintCode.waiting,
        '对照第一张，拍清周围环境',
        '确认同一放置位置，画面清楚即可拍照',
      );
    }
    if (code == HintCode.stale) {
      return const GuideHint(
        HintCode.stale,
        '请确认环境与放置位置能看清',
        '识别暂未更新，仍可直接拍第二张',
      );
    }
    return this;
  }

  bool get isReady => code == HintCode.ready;
  bool get needsAttention => const {
    HintCode.closer,
    HintCode.wider,
    HintCode.blurry,
    HintCode.dark,
    HintCode.glare,
    HintCode.focusing,
  }.contains(code);
  static const waiting = GuideHint(
    HintCode.waiting,
    '对准包裹与周围环境',
    '正在观察画面，你可以随时拍照',
  );
  static const stale = GuideHint(
    HintCode.stale,
    '请确认包裹与位置能看清',
    '识别暂未更新，仍可直接拍照',
  );
}

/// Heuristics for framing assistance, never a delivery/address verification.
class GuidanceRules {
  const GuidanceRules();
  GuideHint evaluate(
    SceneFacts facts,
    ShotStage stage,
    GuideSettings settings,
  ) {
    final quality = stage == ShotStage.environment
        ? facts.clarity?.environmentOnly
        : facts.clarity;
    if (quality != null) {
      final code = switch (quality.state) {
        ClarityState.blurry => HintCode.blurry,
        ClarityState.dark => HintCode.dark,
        ClarityState.glare => HintCode.glare,
        ClarityState.focusing => HintCode.focusing,
        _ => null,
      };
      if (code != null) {
        return GuideHint(
          code,
          quality.state == ClarityState.focusing
              ? '请稳住手机，等待对焦'
              : quality.state == ClarityState.dark
              ? '画面较暗，请补光'
              : quality.state == ClarityState.glare
              ? '画面过亮，请调整角度'
              : '画面可能模糊，请稳住手机',
          quality.advice,
        );
      }
    }
    final package = facts.package(settings);
    final anchors = facts.anchors(settings);
    // A box is an image footprint, not a measurement of physical distance.
    // Only obvious extremes with stronger detection evidence merit a suggestion.
    final canSuggestFraming = package != null && package.confidence >= .65;
    final obviousCloseUp =
        package != null &&
        (package.touchesEdge &&
            package.area > .35 &&
            math.max(package.clipped.width, package.clipped.height) > .8);
    if (stage == ShotStage.parcel) {
      if (package == null) {
        return const GuideHint(
          HintCode.packageMissing,
          '请确认包裹与位置能看清',
          '识别暂未确认；完整包裹和放置位置清楚即可拍照',
        );
      }
      if (canSuggestFraming &&
          package.area < .003 &&
          package.clipped.width < .06 &&
          package.clipped.height < .08) {
        return const GuideHint(HintCode.closer, '包裹细节较小', '可稍靠近或调整角度，同时保留放置位置');
      }
      if (canSuggestFraming && obviousCloseUp) {
        return const GuideHint(
          HintCode.wider,
          '请给包裹四周留些空间',
          '调整角度，让完整包裹和放置位置一起入镜',
        );
      }
      if (anchors.isEmpty) {
        return const GuideHint(
          HintCode.contextUncertain,
          '包裹已入镜，可直接拍照',
          '请确认周围特征能说明放置位置，无需等待识别确认',
        );
      }
      return const GuideHint(HintCode.ready, '已识别到包裹与环境特征', '请确认完整包裹和放置位置都能看清');
    }
    // The second shot is contextual. Without identity matching, another person's
    // bag/box must not drive distance or local-package clarity suggestions.
    if (anchors.isEmpty) {
      return GuideHint(
        HintCode.contextUncertain,
        quality?.state == ClarityState.clear ? '画面较清晰，可拍第二张' : '对照第一张，拍清周围环境',
        '确认同一放置位置，并多拍一些周围环境，无需等待提示变绿',
      );
    }
    return const GuideHint(HintCode.ready, '已识别到环境特征', '请确认能与第一张对应，方便再次寻找');
  }
}

/// A monotonic receive clock avoids wall-clock/time-zone jumps during a session.
class HintStabilizer {
  HintStabilizer({this.requiredFrames = 3, this.holdMs = 800});
  final int requiredFrames;
  final int holdMs;
  GuideHint current = GuideHint.waiting;
  HintCode? _candidate;
  int _count = 0;
  int? _lastChanged;
  int? _lastFrame;

  GuideHint add(GuideHint next, int nowMs) {
    // Clear confidence after interruptions; old votes must not join a new burst.
    if (_lastFrame != null && nowMs - _lastFrame! > 1500) reset();
    _lastFrame = nowMs;
    if (_candidate == next.code) {
      _count++;
    } else {
      _candidate = next.code;
      _count = 1;
    }
    if (_count >= requiredFrames &&
        (_lastChanged == null || nowMs - _lastChanged! >= holdMs)) {
      if (current.code != next.code) _lastChanged = nowMs;
      current = next;
    }
    return current;
  }

  GuideHint at(int nowMs) {
    if (_lastFrame != null && nowMs - _lastFrame! > 1500) {
      reset();
      current = GuideHint.stale;
    }
    return current;
  }

  void reset() {
    current = GuideHint.waiting;
    _candidate = null;
    _count = 0;
    _lastChanged = null;
    _lastFrame = null;
  }
}

class TimingSummary {
  final List<double> _processing = [];
  final List<int> _received = [];
  void add(double processingMs, int receivedAtMs) {
    if (!processingMs.isFinite || processingMs < 0) return;
    _processing.add(processingMs);
    _received.add(receivedAtMs);
    // Bounded window: do not grow per-frame logs during a delivery shift.
    if (_processing.length > 300) {
      _processing.removeAt(0);
      _received.removeAt(0);
    }
  }

  int get count => _processing.length;
  double percentile(double p) {
    if (_processing.isEmpty) return 0;
    final ordered = [..._processing]..sort();
    return ordered[(p * ordered.length).ceil().clamp(1, ordered.length) - 1];
  }

  double get callbackFps =>
      _received.length < 2 || _received.last == _received.first
      ? 0
      : (_received.length - 1) * 1000 / (_received.last - _received.first);
  Map<String, Object> toJson() => {
    'windowFrames': count,
    'processingP50Ms': percentile(.5),
    'processingP95Ms': percentile(.95),
    'callbackFps': callbackFps,
    'scope':
        'SDK inference/postprocessing; not end-to-end prompt latency or camera preview FPS',
  };
}
