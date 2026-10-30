import 'package:delivery_photo_assist/src/domain/performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sustained slow inference degrades; a single spike does not', () {
    final governor = PerformanceGovernor();
    governor.observeModel(700, 100);
    governor.observeModel(20, 400);
    expect(governor.budget.tier, AnalysisTier.standard);
    for (var i = 0; i < 6; i++) {
      governor.observeModel(230, 1000 + i * 500);
    }
    expect(governor.budget.tier, AnalysisTier.reduced);
    expect(governor.budget.fps, 2);
    expect(governor.budget.textEnabled, isFalse);
    for (var i = 0; i < 4; i++) {
      governor.observeModel(500, 5000 + i * 600);
    }
    expect(governor.budget.tier, AnalysisTier.lowFrequency);
    expect(governor.budget.detectionEnabled, isTrue);
    expect(governor.budget.framingEnabled, isFalse);
    expect(governor.budget.fps, 1);
    for (var i = 0; i < 12; i++) {
      governor.observeModel(900, 8000 + i * 1000);
    }
    expect(governor.budget.detectionEnabled, isTrue);
  });
  test(
    'real thermal or memory pressure still pauses detection after slow-device degradation',
    () {
      for (final thermal in [true, false]) {
        final governor = PerformanceGovernor();
        for (var i = 0; i < 4; i++) {
          governor.observeModel(700, i * 1000);
        }
        expect(governor.budget.detectionEnabled, isTrue);
        if (thermal) {
          governor.observeDevice({'thermalLevel': 2}, 5000);
        } else {
          governor.memoryPressure(5000);
        }
        expect(governor.budget.tier, AnalysisTier.minimal);
        expect(governor.budget.detectionEnabled, isFalse);
      }
    },
  );
  test('device pressure lowers work without oscillating on recovery', () {
    final governor = PerformanceGovernor();
    governor.observeDevice({'lowRam': true}, 0);
    expect(governor.budget.tier, AnalysisTier.reduced);
    governor.observeDevice({'thermalLevel': 0, 'lowPower': false}, 5000);
    expect(governor.budget.tier, AnalysisTier.reduced);
    governor.observeDevice({'thermalLevel': 2}, 10000);
    expect(governor.budget.tier, AnalysisTier.minimal);
    governor.observeDevice({'thermalLevel': 0}, 20000);
    expect(governor.budget.tier, AnalysisTier.minimal);
  });
  test(
    'expensive framing pauses itself and memory pressure stops heavy work',
    () {
      final governor = PerformanceGovernor();
      for (var i = 0; i < 3; i++) {
        governor.observeFraming(900, i * 1500);
      }
      expect(governor.budget.framingEnabled, isFalse);
      expect(governor.budget.detectionEnabled, isTrue);
      governor.memoryPressure(5000);
      expect(governor.budget.detectionEnabled, isFalse);
      expect(governor.reason, 'memory_pressure');
    },
  );
  test(
    'UI jank and manual smooth mode reduce workload; startup is ignored',
    () {
      final governor = PerformanceGovernor();
      for (var i = 0; i < 30; i++) {
        governor.observeUiFrame(100, 1000);
      }
      expect(governor.budget.tier, AnalysisTier.standard);
      for (var i = 0; i < 24; i++) {
        governor.observeUiFrame(i < 8 ? 80 : 12, 4000 + i * 100);
      }
      expect(governor.budget.tier, AnalysisTier.reduced);
      final manual = PerformanceGovernor()..preferSmooth = true;
      expect(manual.budget.textEnabled, isFalse);
      expect(manual.budget.framingIntervalMs, 1200);
    },
  );
}
