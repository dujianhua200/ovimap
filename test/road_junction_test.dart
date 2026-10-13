// 道路交叉口处理（开口+倒角）单测：RoadJunction 纯几何模块。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/road_junction.dart';

JunctionRoad _road(List<List<double>> pts, RoadGrade g, double halfW) =>
    JunctionRoad(pts, g, halfW);

double _len(List<List<double>> pts) {
  var t = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i][0] - pts[i - 1][0], dy = pts[i][1] - pts[i - 1][1];
    t += dx * dx + dy * dy;
  }
  return t;
}

void main() {
  group('RoadJunction', () {
    test('无交叉：pieces 保持原样、无倒角', () {
      final roads = [
        _road([
          [0, 0],
          [100, 0]
        ], RoadGrade.trunk, 0.9),
        _road([
          [0, 50],
          [100, 50]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, 0.3);
      expect(r.pieces[0].length, 1);
      expect(r.pieces[1].length, 1);
      expect(_len(r.pieces[0][0]), closeTo(10000, 1e-6));
      expect(r.chamfers, isEmpty);
    });

    test('十字交叉：次路开口退让、主路贯通、4 条倒角', () {
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        _road([
          [0, -100],
          [0, 100]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer);
      // 主路贯通
      expect(r.pieces[0].length, 1);
      expect(_len(r.pieces[0][0]), closeTo(40000, 1e-6));
      // 次路被切成 2 段，开口半宽 = trunkHW + chamfer
      expect(r.pieces[1].length, 2);
      final trim = trunkHW + chamfer;
      // 第一段：-100 → -trim；第二段：trim → 100
      expect(r.pieces[1][0].first[1], closeTo(-100, 1e-6));
      expect(r.pieces[1][0].last[1], closeTo(-trim, 1e-6));
      expect(r.pieces[1][1].first[1], closeTo(trim, 1e-6));
      expect(r.pieces[1][1].last[1], closeTo(100, 1e-6));
      // 倒角：2 个开口端 × 2 角 = 4
      expect(r.chamfers.length, 4);
      for (final ch in r.chamfers) {
        // 倒角线很短（约 chamfer 量级）
        final dx = ch[0][0] - ch[1][0], dy = ch[0][1] - ch[1][1];
        final d = dx * dx + dy * dy;
        expect(d, lessThan(4.0));
        expect(d, greaterThan(1e-12));
        // 45° 真倒角：落点 q 在主路边线上（|y| = trunkHW），且两条腿等长
        expect(ch[1][1].abs(), closeTo(trunkHW, 1e-6),
            reason: '倒角落点应在主路边线上，实测 ${ch[1]}');
        expect(dx.abs(), closeTo(dy.abs(), 1e-6),
            reason: '45° 倒角两条腿应等长，实测 $ch');
      }
    });

    test('T 型交叉：次路端点顶在主路上，开口+2 倒角', () {
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        _road([
          [0, 0],
          [0, 100]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer);
      expect(r.pieces[0].length, 1);
      // 次路从 trim 处开始
      expect(r.pieces[1].length, 1);
      expect(r.pieces[1][0].first[1], closeTo(trunkHW + chamfer, 1e-6));
      expect(r.pieces[1][0].last[1], closeTo(100, 1e-6));
      expect(r.chamfers.length, 2);
    });

    test('同级交叉：索引小者为 major，另一条退让', () {
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.tertiary, 0.5),
        _road([
          [0, -100],
          [0, 100]
        ], RoadGrade.tertiary, 0.5),
      ];
      final r = RoadJunction.process(roads, 0.3);
      expect(r.pieces[0].length, 1); // 索引 0 为 major，贯通
      expect(r.pieces[1].length, 2); // 索引 1 退让
      expect(r.chamfers.length, 4);
    });

    test('高等级路交叉低等级：高等级贯通（反向输入顺序亦然）', () {
      final roads = [
        _road([
          [0, -100],
          [0, 100]
        ], RoadGrade.service, 0.24),
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.primary, 0.76),
      ];
      final r = RoadJunction.process(roads, 0.3);
      // service（索引0）虽在前，等级低 → 退让
      expect(r.pieces[0].length, 2);
      // primary 贯通
      expect(r.pieces[1].length, 1);
    });

    test('平行邻近道路不误判为交叉口', () {
      final roads = [
        _road([
          [0, 0],
          [100, 0]
        ], RoadGrade.trunk, 0.9),
        _road([
          [0, 1.0],
          [100, 1.0]
        ], RoadGrade.trunk, 0.9),
      ];
      final r = RoadJunction.process(roads, 0.3);
      expect(r.pieces[0].length, 1);
      expect(r.pieces[1].length, 1);
      expect(r.chamfers, isEmpty);
    });

    test('共用端点（同一条路的分段 way）不视为交叉口', () {
      final roads = [
        _road([
          [0, 0],
          [100, 0]
        ], RoadGrade.trunk, 0.9),
        _road([
          [100, 0],
          [200, 0]
        ], RoadGrade.trunk, 0.9),
      ];
      final r = RoadJunction.process(roads, 0.3);
      // 两段首尾相接：各自保持完整，不开口、无倒角
      expect(r.pieces[0].length, 1);
      expect(r.pieces[1].length, 1);
      expect(_len(r.pieces[0][0]), closeTo(10000, 1e-6));
      expect(_len(r.pieces[1][0]), closeTo(10000, 1e-6));
      expect(r.chamfers, isEmpty);
    });

    test('空输入/单点输入不崩', () {
      expect(RoadJunction.process([], 0.3).pieces, isEmpty);
      final r = RoadJunction.process([
        _road([
          [1, 1]
        ], RoadGrade.trunk, 0.9)
      ], 0.3);
      expect(r.pieces[0], isEmpty);
      expect(r.chamfers, isEmpty);
    });

    test('近miss容差：T 型口 2m 间隙仍识别为交叉口', () {
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        // 次路端点 (0,2) 距主路 2m（间隙），snapTol=3 应抓住
        _road([
          [0, 2],
          [0, 100]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer, snapTol: 3.0);
      // 次路起点在 trim 区外（2m > 1.2m），不被切断，但应有倒角连到主路边线
      expect(r.pieces[1].length, 1);
      expect(r.pieces[1][0].first, [0, 2]);
      expect(r.chamfers.length, 2);
    });

    test('近miss容差：间隙超容差不识别', () {
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        // 次路端点 (0,5) 距主路 5m，snapTol=3 抓不住
        _road([
          [0, 5],
          [0, 100]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer, snapTol: 3.0);
      // 次路保持完整，无开口、无倒角
      expect(r.pieces[1].length, 1);
      expect(r.chamfers, isEmpty);
    });

    test('近miss容差：平行路 1m 间距不误判（即使在容差内）', () {
      final roads = [
        _road([
          [0, 0],
          [100, 0]
        ], RoadGrade.trunk, 0.9),
        _road([
          [0, 1.0],
          [100, 1.0]
        ], RoadGrade.trunk, 0.9),
      ];
      final r = RoadJunction.process(roads, 0.3, snapTol: 3.0);
      expect(r.pieces[0].length, 1);
      expect(r.pieces[1].length, 1);
      expect(r.chamfers, isEmpty);
    });

    test('近miss容差：snapTol=0 时不兜底', () {
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        _road([
          [0, 2],
          [0, 100]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer, snapTol: 0);
      expect(r.pieces[1].length, 1);
      expect(r.chamfers, isEmpty);
    });

    test('倒角去重：同一路口双次路近端点不产生重复倒角', () {
      // 主路东西向，两条次路南北向，次路与主路交点相差 1.5m
      // （同一路口的两个检测点），去重后倒角不应成对重复
      const trunkHW = 0.9, chamfer = 0.3;
      final roads = [
        _road([
          [-100, 0],
          [100, 0]
        ], RoadGrade.trunk, trunkHW),
        _road([
          [0, 100],
          [0, 0]
        ], RoadGrade.residential, 0.36),
        _road([
          [1.5, 100],
          [1.5, 0]
        ], RoadGrade.residential, 0.36),
      ];
      final r = RoadJunction.process(roads, chamfer, snapTol: 3.0);
      // 任意两条倒角不应近似重合（中点 < 2m、方向平行、且中点偏移沿倒角方向）
      for (var i = 0; i < r.chamfers.length; i++) {
        for (var j = i + 1; j < r.chamfers.length; j++) {
          final c1 = r.chamfers[i], c2 = r.chamfers[j];
          final m1x = (c1[0][0] + c1[1][0]) / 2,
              m1y = (c1[0][1] + c1[1][1]) / 2;
          final m2x = (c2[0][0] + c2[1][0]) / 2,
              m2y = (c2[0][1] + c2[1][1]) / 2;
          final offx = m1x - m2x, offy = m1y - m2y;
          final offLen = math.sqrt(offx * offx + offy * offy);
          final d1x = c1[1][0] - c1[0][0], d1y = c1[1][1] - c1[0][1];
          final d2x = c2[1][0] - c2[0][0], d2y = c2[1][1] - c2[0][1];
          final l1 = math.sqrt(d1x * d1x + d1y * d1y);
          final l2 = math.sqrt(d2x * d2x + d2y * d2y);
          final cosA = (d1x * d2x + d1y * d2y) / (l1 * l2);
          final alongRatio =
              (offx * d1x + offy * d1y).abs() / (offLen * l1);
          final isDup =
              offLen < 2.0 && cosA.abs() > 0.86 && alongRatio > 0.7;
          expect(isDup, isFalse, reason: '倒角 $i 与 $j 重复');
        }
      }
    });
  });
}
