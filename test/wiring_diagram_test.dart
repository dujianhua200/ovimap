import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name, double lat, double lon) =>
      MapLabel(id: id, name: name, lat: lat, lon: lon);

  group('layoutWiringDiagram（地理同向压缩，2026-10-08）', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
    });

    test('线性拓扑保持地理方向', () {
      // 三个点自西向东排列
      final ds = [
        dev('a', 'OLT', 32.0, 114.0),
        dev('b', 'GX-01', 32.0, 114.001),
        dev('c', 'FH-01', 32.0, 114.002),
      ];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'b', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.nodes.length, 3);
      expect(l.edges.length, 2);
      // x 坐标反映经度顺序（自西向东递增），与路由图同向
      final byId = {for (final n in l.nodes) n.device.id: n};
      expect(byId['a']!.x < byId['b']!.x, isTrue);
      expect(byId['b']!.x < byId['c']!.x, isTrue);
      // y 基本一致（同纬度）
      expect((byId['a']!.y - byId['b']!.y).abs() < 1, isTrue);
    });

    test('无效连线被过滤', () {
      final ds = [dev('a', 'A', 32.0, 114.0)];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'zzz')];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.nodes.length, 1);
      expect(l.edges, isEmpty);
    });

    test('不同位置节点位置不同', () {
      final ds = [
        dev('a', 'A', 32.0, 114.0),
        dev('b', 'B', 32.001, 114.001),
      ];
      final l = layoutWiringDiagram(ds, []);
      expect(l.nodes.length, 2);
      // 地理不同，排布位置不同
      final dx = (l.nodes[0].x - l.nodes[1].x).abs();
      final dy = (l.nodes[0].y - l.nodes[1].y).abs();
      expect(dx + dy > 0, isTrue);
    });

    test('分支拓扑保持相对方向', () {
      final ds = [
        dev('a', 'OLT', 32.0, 114.0),
        dev('b', 'B', 32.001, 114.001),
        dev('c', 'C', 31.999, 114.001),
      ];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'a', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.edges.length, 2);
      final byId = {for (final n in l.nodes) n.device.id: n};
      // b 在北，c 在南，y 坐标反映纬度
      expect(byId['b']!.y > byId['c']!.y, isTrue);
      // b/c 都在 a 以东
      expect(byId['b']!.x > byId['a']!.x, isTrue);
      expect(byId['c']!.x > byId['a']!.x, isTrue);
    });

    test('距离被压缩但方向不变', () {
      // 实际相距约 111m 的两点，压缩后距离 < 111m 但 > 0
      final ds = [
        dev('a', 'A', 32.0, 114.0),
        dev('b', 'B', 32.001, 114.0), // 纬度差 0.001 ≈ 111m
      ];
      final l = layoutWiringDiagram(ds, [], maxWidth: 400, maxHeight: 300);
      final dx = (l.nodes[0].x - l.nodes[1].x).abs();
      final dy = (l.nodes[0].y - l.nodes[1].y).abs();
      final dist = dx + dy;
      expect(dist > 0, isTrue);
      expect(dist < 111, isTrue); // 被压缩
      // b 在北，y 更大
      final byId = {for (final n in l.nodes) n.device.id: n};
      expect(byId['b']!.y > byId['a']!.y, isTrue);
    });
  });
}
