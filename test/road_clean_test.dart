// 道路拓扑修复单测：cleanRoads（删零长度段 + 同名端点吸附）。
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/bundled_basemap.dart';

RoadPoly _road(List<List<double>> pts, String name,
        [RoadGrade g = RoadGrade.primary]) =>
    RoadPoly(pts, g, name);

void main() {
  group('BundledBasemap.cleanRoads', () {
    test('删零长度段：0m 和 <2m 的段被去掉，正常段保留', () {
      final roads = [
        _road([
          [32.13, 114.08],
          [32.13, 114.08]
        ], '零长度路'),
        _road([
          [32.13, 114.08],
          [32.13001, 114.08]
        ], '极短路'), // ~1.1m
        _road([
          [32.13, 114.08],
          [32.131, 114.08]
        ], '正常路'), // ~110m
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 1);
      expect(out[0].name, '正常路');
    });

    test('吸附：同名路 10m 间隙吸合到同一点', () {
      // 四一路两段，端点相距约 10m
      final roads = [
        _road([
          [32.13, 114.08],
          [32.1301, 114.08]
        ], '四一路'),
        _road([
          [32.1301, 114.0801],
          [32.131, 114.08]
        ], '四一路'),
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 2);
      // 第一段终点 == 第二段起点（吸合到质心）
      expect(out[0].pts.last[0], closeTo(out[1].pts.first[0], 1e-9));
      expect(out[0].pts.last[1], closeTo(out[1].pts.first[1], 1e-9));
    });

    test('吸附：15m 外的同名端点不吸合', () {
      final roads = [
        _road([
          [32.13, 114.08],
          [32.1301, 114.08]
        ], '四一路'),
        _road([
          [32.1301, 114.0803],
          [32.131, 114.08]
        ], '四一路'), // 端点相距约 28m
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 2);
      // 端点不重合
      expect(
          (out[0].pts.last[0] - out[1].pts.first[0]).abs() > 1e-9 ||
              (out[0].pts.last[1] - out[1].pts.first[1]).abs() > 1e-9,
          isTrue);
    });

    test('吸附：平行路（不同名）近端点不误吸', () {
      // 双向车道：两条平行路，端点相距 5m，但名字不同
      final roads = [
        _road([
          [32.13, 114.08],
          [32.131, 114.08]
        ], '中山路东向'),
        _road([
          [32.13, 114.08005],
          [32.131, 114.08005]
        ], '中山路西向'),
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 2);
      // 端点保持原位（不吸合）
      expect(out[0].pts.first[1], closeTo(114.08, 1e-9));
      expect(out[1].pts.first[1], closeTo(114.08005, 1e-9));
    });

    test('吸附：异名路交叉角端点吸合（同一路口）', () {
      // 人民路（东西向）与民权路（南北向）在路口相遇，端点相距约 5m
      final roads = [
        _road([
          [32.13, 114.08],
          [32.13, 114.081]
        ], '人民路'), // 东西向，终点 (32.13, 114.081)
        _road([
          [32.129, 114.08105],
          [32.13, 114.08105]
        ], '民权路'), // 南北向，终点 (32.13, 114.08105)，距人民路终点约 4.7m
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 2);
      // 两路终点吸合到同一点
      expect(out[0].pts.last[0], closeTo(out[1].pts.last[0], 1e-9));
      expect(out[0].pts.last[1], closeTo(out[1].pts.last[1], 1e-9));
    });

    test('吸附：无名路不吸附', () {
      final roads = [
        _road([
          [32.13, 114.08],
          [32.1301, 114.08]
        ], ''),
        _road([
          [32.1301, 114.0801],
          [32.131, 114.08]
        ], ''),
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 2);
      expect(
          (out[0].pts.last[0] - out[1].pts.first[0]).abs() > 1e-9 ||
              (out[0].pts.last[1] - out[1].pts.first[1]).abs() > 1e-9,
          isTrue);
    });

    test('吸附：三段同路传递吸合（A-B, B-C 近，A-C 远）', () {
      final roads = [
        _road([
          [32.13, 114.08],
          [32.1301, 114.08]
        ], '四一路'),
        _road([
          [32.1301, 114.08008],
          [32.1302, 114.08008]
        ], '四一路'),
        _road([
          [32.1302, 114.08016],
          [32.131, 114.08]
        ], '四一路'),
      ];
      final out = BundledBasemap.cleanRoads(roads);
      expect(out.length, 3);
      // 第一段终点 == 第二段起点
      expect(out[0].pts.last[0], closeTo(out[1].pts.first[0], 1e-9));
      // 第二段终点 == 第三段起点
      expect(out[1].pts.last[0], closeTo(out[2].pts.first[0], 1e-9));
    });

    test('空输入不崩', () {
      expect(BundledBasemap.cleanRoads([]), isEmpty);
    });

    test('mergeRoads 同样清洗（零长度段被删）', () {
      final bundled = [
        _road([
          [32.13, 114.08],
          [32.13, 114.08]
        ], '零长度路'),
      ];
      final live = [
        _road([
          [32.13, 114.08],
          [32.131, 114.08]
        ], '正常路'),
      ];
      final out = BundledBasemap.mergeRoads(bundled, live);
      expect(out.length, 1);
      expect(out[0].name, '正常路');
    });
  });
}
