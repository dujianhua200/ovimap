import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/design/pole_placer.dart';
import 'package:ovimap/geo/geo_util.dart';

/// 智能布杆（[PolePlacer]）单测：纯 Dart 计算模块。
void main() {
  // 赤道上 1 经度 ≈ 的米数（测试构造用，断言一律走 haversine）。
  const mPerDeg = 6371000 * math.pi / 180;

  RoutePoint pt(double lat, double lon) => RoutePoint(lat, lon);

  /// 起点 (0,0) 向东 [meters] 米的点。
  RoutePoint east(double meters) => pt(0, meters / mPerDeg);

  double dist(PolePlan a, PolePlan b) =>
      GeoUtil.haversine(a.lat, a.lon, b.lat, b.lon);

  group('编号', () {
    test('递增与补零：G001、G002、G003', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), east(120)],
        spanM: 50,
        prefix: 'G',
        startNo: 1,
        digits: 3,
      );
      expect(plans.map((p) => p.name).toList(),
          equals(['G001', 'G002', 'G003']));
    });

    test('自定义前缀/起始号/位数：T009 起', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), east(120)],
        spanM: 50,
        prefix: 'T',
        startNo: 9,
        digits: 3,
      );
      expect(plans.map((p) => p.name).toList(),
          equals(['T009', 'T010', 'T011']));
    });

    test('位数不足不截断：99 起 2 位 → G99、G100', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), east(120)],
        spanM: 50,
        prefix: 'G',
        startNo: 99,
        digits: 2,
      );
      expect(
          plans.map((p) => p.name).toList(), equals(['G99', 'G100', 'G101']));
    });
  });

  group('档距布点', () {
    test('直线 120m、档距 50 → 3 根，位置 0/50/100m', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), east(120)],
        spanM: 50,
      );
      expect(plans.length, 3);
      // 起点
      expect(plans[0].lat, closeTo(0, 1e-9));
      expect(plans[0].lon, closeTo(0, 1e-9));
      // 弧长位置：与起点的 haversine 距离 ≈ 50 / 100
      expect(dist(plans[0], plans[1]), closeTo(50, 1.0));
      expect(dist(plans[0], plans[2]), closeTo(100, 1.0));
      // 落在直线上
      expect(plans[1].lat, closeTo(0, 1e-6));
      expect(plans[2].lat, closeTo(0, 1e-6));
    });

    test('spanM 非法 → 抛 ArgumentError', () {
      expect(
        () => PolePlacer.place(route: [pt(0, 0), east(10)], spanM: 0),
        throwsArgumentError,
      );
    });
  });

  group('拐点必立杆', () {
    // L 形：A(0,0) → B(东60m) → C(东60m,北60m)，B 处转角 90°。
    List<RoutePoint> lRoute() =>
        [pt(0, 0), east(60), pt(60 / mPerDeg, 60 / mPerDeg)];

    double distToCorner(PolePlan p) =>
        GeoUtil.haversine(p.lat, p.lon, 0, 60 / mPerDeg);

    test('默认开启：拐点处有杆', () {
      final plans = PolePlacer.place(route: lRoute(), spanM: 50);
      final nearCorner =
          plans.where((p) => distToCorner(p) < 2.0).toList();
      expect(nearCorner.length, 1);
      // 拐点立杆后档距从拐点重算：最大档距不超过档距
      expect(PolePlacer.maxSpanM(plans), lessThanOrEqualTo(50.5));
    });

    test('关闭后：拐点处无杆', () {
      final plans = PolePlacer.place(
          route: lRoute(), spanM: 50, cornerMustHave: false);
      final nearCorner =
          plans.where((p) => distToCorner(p) < 5.0).toList();
      expect(nearCorner, isEmpty);
      // 0/50/100：100m 弧长点落在第二段，距拐点 40m
      expect(plans.length, 3);
      expect(distToCorner(plans[2]), closeTo(40, 1.0));
    });

    test('小转角（20°）不强制立杆', () {
      final ang = 20 * math.pi / 180;
      final b = east(60);
      // B → C：方向东偏北 20°，再走 60m。
      final cc = pt(
        60 * math.sin(ang) / mPerDeg,
        (60 + 60 * math.cos(ang)) / mPerDeg,
      );
      final plans = PolePlacer.place(route: [pt(0, 0), b, cc], spanM: 50);
      final nearB = plans.where(
          (p) => GeoUtil.haversine(p.lat, p.lon, b.lat, b.lon) < 2.0);
      expect(nearB, isEmpty);
    });
  });

  group('边界', () {
    test('空线路 → 空', () {
      expect(PolePlacer.place(route: const []), isEmpty);
    });

    test('总长不足一档（30m < 50m）→ 起点立一根', () {
      final plans = PolePlacer.place(route: [pt(0, 0), east(30)], spanM: 50);
      expect(plans.length, 1);
      expect(plans[0].lat, closeTo(0, 1e-9));
      expect(plans[0].lon, closeTo(0, 1e-9));
      expect(plans[0].name, 'G001');
    });

    test('单点线路 → 该点立一根', () {
      final plans = PolePlacer.place(route: [pt(1.5, 2.5)], spanM: 50);
      expect(plans.length, 1);
      expect(plans[0].lat, 1.5);
      expect(plans[0].lon, 2.5);
    });

    test('连续重复点不影响布点', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), pt(0, 0), east(120), east(120)],
        spanM: 50,
      );
      expect(plans.length, 3);
      expect(dist(plans[0], plans[1]), closeTo(50, 1.0));
    });
  });

  group('杆号查重顺延', () {
    test('已占用 G001、G003 → 从 G002 起顺延', () {
      final plans = PolePlacer.place(
        route: [pt(0, 0), east(120)],
        spanM: 50,
        takenNames: {'G001', 'G003'},
      );
      expect(plans.map((p) => p.name).toList(),
          equals(['G002', 'G004', 'G005']));
    });

    test('assignNames 独立调用：跳过占用且不重复', () {
      final poles = [
        PolePlan(lat: 0, lon: 0),
        PolePlan(lat: 0, lon: 1),
      ];
      PolePlacer.assignNames(poles,
          prefix: 'X', startNo: 5, digits: 2, takenNames: {'X05'});
      expect(poles.map((p) => p.name).toList(), equals(['X06', 'X07']));
    });
  });

  group('辅助', () {
    test('maxSpanM：空/单根 → 0', () {
      expect(PolePlacer.maxSpanM(const []), 0);
      expect(PolePlacer.maxSpanM([PolePlan(lat: 0, lon: 0)]), 0);
    });

    test('routeLengthM：120m 直线 ≈ 120', () {
      expect(
          PolePlacer.routeLengthM([pt(0, 0), east(120)]), closeTo(120, 0.5));
    });
  });
}
