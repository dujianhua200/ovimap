import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name) => MapLabel(id: id, name: name);

  group('layoutWiringDiagram（水平总线式，按路由顺序，2026-10-08）', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], [], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
    });

    test('按路由顺序左右排', () {
      // 路由链顺序：a -> b -> c
      final route = [dev('a', 'OLT'), dev('b', 'GX-01'), dev('c', 'FH-01')];
      // 设备乱序传入，应按路由顺序排
      final ds = [dev('c', 'FH-01'), dev('a', 'OLT'), dev('b', 'GX-01')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'b', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes.length, 3);
      expect(l.edges.length, 2);
      // a 最左，c 最右
      expect(l.nodes[0].device.id, 'a');
      expect(l.nodes[1].device.id, 'b');
      expect(l.nodes[2].device.id, 'c');
      expect(l.nodes[0].x < l.nodes[1].x, isTrue);
      expect(l.nodes[1].x < l.nodes[2].x, isTrue);
      // 都在总线下方同一高度
      expect(l.nodes[0].y, l.nodes[1].y);
      expect(l.nodes[1].y, l.nodes[2].y);
    });

    test('无效连线被过滤', () {
      final ds = [dev('a', 'A')];
      final route = [dev('a', 'A')];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'zzz')];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes.length, 1);
      expect(l.edges, isEmpty);
    });

    test('不在路由链中的设备放末尾', () {
      final route = [dev('a', 'A')];
      final ds = [dev('a', 'A'), dev('x', 'X')];
      final l = layoutWiringDiagram(ds, [], route);
      expect(l.nodes.length, 2);
      expect(l.nodes[0].device.id, 'a');
      expect(l.nodes[1].device.id, 'x');
    });

    test('连线方向不影响排布顺序', () {
      // 连线是 c->a（逆向），但路由顺序是 a->b->c，排布仍按路由
      final route = [dev('a', 'A'), dev('b', 'B'), dev('c', 'C')];
      final ds = [dev('a', 'A'), dev('b', 'B'), dev('c', 'C')];
      final ls = [FiberLink(fromDeviceId: 'c', toDeviceId: 'a')];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes[0].device.id, 'a');
      expect(l.nodes[2].device.id, 'c');
      expect(l.edges.length, 1);
    });
  });
}
