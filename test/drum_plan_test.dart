import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/design/drum_plan.dart';
import 'package:ovimap/models/map_label.dart';

const _p = DrumPlanParams(
  drumLengthM: 2000,
  spliceSlackM: 0,
  minRemnantM: 100,
);

CableSeg seg(double len, {String model = '48芯GYTS', bool riser = false}) =>
    CableSeg(
      label: 'A→B',
      lengthM: len,
      cableModel: model,
      hasRiser: riser,
    );

void main() {
  group('planDrums', () {
    test('基本装盘：3 段 600m、盘长 2000 → 1 盘', () {
      final plans = planDrums(
          [seg(600), seg(600), seg(600)], _p);
      expect(plans, hasLength(1));
      expect(plans.first.drumNo, 1);
      expect(plans.first.usedM, 1800);
      expect(plans.first.warnings, isEmpty);
    });

    test('装不下则开新盘：3 段 800m → 2 盘（1600 + 800）', () {
      final plans = planDrums(
          [seg(800), seg(800), seg(800)], _p);
      expect(plans, hasLength(2));
      expect(plans[0].usedM, 1600);
      expect(plans[1].usedM, 800);
      expect(plans[1].drumNo, 2);
    });

    test('换型号开新盘', () {
      final plans = planDrums(
          [seg(800), seg(800, model: '24芯GYTA')], _p);
      expect(plans, hasLength(2));
      expect(plans[0].cableModel, '48芯GYTS');
      expect(plans[1].cableModel, '24芯GYTA');
      expect(plans[1].drumNo, 2);
    });

    test('超长段独占一盘并告警', () {
      final plans = planDrums([seg(800), seg(2500)], _p);
      expect(plans, hasLength(2));
      final over = plans[1];
      expect(over.segs, contains('第2段'));
      expect(over.warnings.any((w) => w.contains('超长告警')), isTrue);
      // 超长独占盘不再重复报余缆
      expect(over.warnings.any((w) => w.contains('余缆')), isFalse);
    });

    test('预留计入：800 + 15 接头预留 = 815', () {
      const p = DrumPlanParams(
          drumLengthM: 2000, spliceSlackM: 15, minRemnantM: 100);
      final plans = planDrums([seg(800)], p);
      expect(plans, hasLength(1));
      expect(plans.first.usedM, 815);
    });

    test('引上预留计入与开关', () {
      const p = DrumPlanParams(
          drumLengthM: 2000, spliceSlackM: 15, riserSlackM: 15);
      final on = planDrums([seg(800, riser: true)], p);
      expect(on.first.usedM, 830);
      const off =
          DrumPlanParams(drumLengthM: 2000, spliceSlackM: 15, riserSlackM: 15,
              countRiserSlack: false);
      final noRiser = planDrums([seg(800, riser: true)], off);
      expect(noRiser.first.usedM, 815);
    });

    test('余缆过短告警：余缆 50m < 阈值 100m', () {
      final plans = planDrums([seg(1800), seg(150)], _p);
      expect(plans, hasLength(1));
      expect(plans.first.usedM, 1950);
      expect(plans.first.warnings.any((w) => w.contains('余缆过短告警')),
          isTrue);
    });

    test('余缆刚好等于阈值不告警', () {
      final plans = planDrums([seg(1800), seg(100)], _p);
      expect(plans, hasLength(1));
      expect(plans.first.warnings, isEmpty);
    });

    test('空输入 → 空结果', () {
      expect(planDrums([], _p), isEmpty);
    });

    test('利用率 = 已用/盘长', () {
      final plans = planDrums([seg(1000)], _p);
      expect(plans.first.utilization, closeTo(0.5, 1e-9));
    });

    test('段落范围描述：多段合并为"第1~3段"', () {
      final plans = planDrums([
        const CableSeg(label: 'GK1→GK2', lengthM: 100, cableModel: '48芯GYTS'),
        const CableSeg(label: 'GK2→GK3', lengthM: 100, cableModel: '48芯GYTS'),
      ], _p);
      expect(plans, hasLength(1));
      expect(plans.first.segs, '第1~2段（GK1→GK3）');
    });
  });

  group('buildCableSegsFromLabels', () {
    List<MapLabel> labels() => [
          MapLabel(
              typeId: 'pipe',
              seq: 1,
              lat: 32.0,
              lon: 114.0,
              name: 'GK-1',
              lineGroupId: 'g',
              distanceM: 100,
              segCable: '48芯GYTS'),
          MapLabel(
              typeId: 'pipe',
              seq: 2,
              lat: 32.001,
              lon: 114.0,
              name: 'GK-2',
              lineGroupId: 'g',
              distanceM: 200,
              segCable: ''),
        ];

    test('每条链连续两点为一段，label 取"起点名→终点名"', () {
      final segs = buildCableSegsFromLabels(labels());
      expect(segs, hasLength(1));
      expect(segs.first.label, 'GK-1→GK-2');
    });

    test('段长口径：distanceM 优先', () {
      final segs = buildCableSegsFromLabels(labels());
      // 第二点 distanceM=200，且该段 cableModel 取终点 segCable（空→未填型号）
      expect(segs.first.lengthM, 200);
      expect(segs.first.cableModel, unsetCableModel);
    });

    test('无 distanceM 时回退 haversine', () {
      final ls = labels()..forEach((l) => l.distanceM = null);
      final segs = buildCableSegsFromLabels(ls);
      // 0.001° 纬度 ≈ 111.2m
      expect(segs.first.lengthM, closeTo(111.2, 0.5));
    });

    test('同组序号区间内有引上点 → hasRiser', () {
      final ls = labels();
      ls.add(MapLabel(
          typeId: 'riser',
          seq: 2,
          lat: 32.0005,
          lon: 114.0,
          name: '引上1',
          lineGroupId: 'g'));
      final segs = buildCableSegsFromLabels(ls);
      expect(segs, hasLength(1));
      expect(segs.first.hasRiser, isTrue);
    });

    test('引上点不在同组 → hasRiser 为假', () {
      final ls = labels();
      ls.add(MapLabel(
          typeId: 'riser',
          seq: 2,
          lat: 32.0005,
          lon: 114.0,
          name: '引上1',
          lineGroupId: 'other'));
      final segs = buildCableSegsFromLabels(ls);
      expect(segs, hasLength(1));
      expect(segs.first.hasRiser, isFalse);
    });
  });
}
