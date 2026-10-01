// 道路交叉口处理（开口+倒角）单测：RoadJunction 纯几何模块。
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
  });
}
