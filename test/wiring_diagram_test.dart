import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name) => MapLabel(id: id, name: name);

  group('layoutWiringDiagram', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
    });

    test('线性拓扑分层', () {
      final ds = [dev('a', 'OLT'), dev('b', 'GX-01'), dev('c', 'FH-01')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'b', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.nodes.length, 3);
      expect(l.edges.length, 2);
      // a 在第0层（x=0），b 在第1层，c 在第2层
      final byId = {for (final n in l.nodes) n.device.id: n};
      expect(byId['a']!.x, 0);
      expect(byId['b']!.x, 60);
      expect(byId['c']!.x, 120);
    });

    test('无效连线被过滤', () {
      final ds = [dev('a', 'A')];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'zzz')];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.nodes.length, 1);
      expect(l.edges, isEmpty);
    });

    test('孤立节点单独成层', () {
      final ds = [dev('a', 'A'), dev('b', 'B')];
      final l = layoutWiringDiagram(ds, []);
      expect(l.nodes.length, 2);
      // 两个都是第0层，同 x，不同 y
      expect(l.nodes[0].x, l.nodes[1].x);
      expect(l.nodes[0].y, isNot(l.nodes[1].y));
    });

    test('分支拓扑', () {
      final ds = [dev('a', 'OLT'), dev('b', 'B'), dev('c', 'C')];
      final ls = [
        FiberLink(fromDeviceId: 'a', toDeviceId: 'b'),
        FiberLink(fromDeviceId: 'a', toDeviceId: 'c'),
      ];
      final l = layoutWiringDiagram(ds, ls);
      expect(l.edges.length, 2);
      final byId = {for (final n in l.nodes) n.device.id: n};
      expect(byId['b']!.x, 60);
      expect(byId['c']!.x, 60);
      expect(byId['b']!.y, isNot(byId['c']!.y));
    });
  });
}
