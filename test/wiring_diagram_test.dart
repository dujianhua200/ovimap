import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name, int seq, double lat, double lon) =>
      MapLabel(id: id, name: name, seq: seq, lat: lat, lon: lon);

  group('layoutWiringDiagram（直角简化，跟路由走向，2026-10-08）', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], [], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
      expect(l.path, isEmpty);
    });

    test('按 seq 排序，路径跟路由走向', () {
      // 三个点：a(西) -> b(东) -> c(东偏南)
      // 地理：a(114.0,32.0) b(114.001,32.0) c(114.001,31.999)
      final route = [
        dev('a', 'OLT', 1, 32.0, 114.0),
        dev('b', 'GX', 2, 32.0, 114.001),
        dev('c', 'FH', 3, 31.999, 114.001),
      ];
      final ds = [
        dev('c', 'FH', 3, 31.999, 114.001),
        dev('a', 'OLT', 1, 32.0, 114.0),
        dev('b', 'GX', 2, 32.0, 114.001),
      ];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'b', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes.length, 3);
      // 按 seq 排：a, b, c
      expect(l.nodes[0].device.id, 'a');
      expect(l.nodes[1].device.id, 'b');
      expect(l.nodes[2].device.id, 'c');
      // 路径：a->b 向东（右），b->c 向南（下）
      // 第一段：x 增加（右）
      expect(l.path[1].x > l.path[0].x, isTrue);
      expect(l.path[1].y == l.path[0].y, isTrue);
      // 第二段：y 减小（下）
      expect(l.path[2].y < l.path[1].y, isTrue);
      expect(l.path[2].x == l.path[1].x, isTrue);
    });

    test('无效连线被过滤', () {
      final route = [dev('a', 'A', 1, 32.0, 114.0)];
      final ds = [dev('a', 'A', 1, 32.0, 114.0)];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'zzz')];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes.length, 1);
      expect(l.edges, isEmpty);
    });

    test('连线方向不影响排布（按 seq）', () {
      // 连线 c->a 逆向，但 seq 是 a(1)->b(2)->c(3)，仍按 seq 排
      final route = [
        dev('a', 'A', 1, 32.0, 114.0),
        dev('b', 'B', 2, 32.0, 114.001),
        dev('c', 'C', 3, 32.0, 114.002),
      ];
      final ds = [
        dev('a', 'A', 1, 32.0, 114.0),
        dev('b', 'B', 2, 32.0, 114.001),
        dev('c', 'C', 3, 32.0, 114.002),
      ];
      final ls = [FiberLink(fromDeviceId: 'c', toDeviceId: 'a')];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes[0].device.id, 'a');
      expect(l.nodes[2].device.id, 'c');
      expect(l.edges.length, 1);
    });
  });
}
