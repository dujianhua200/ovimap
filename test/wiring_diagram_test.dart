import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name, int seq, double lat, double lon) =>
      MapLabel(id: id, name: name, seq: seq, lat: lat, lon: lon);

  // 完整路由链：a(杆) -> b(纤) -> c(杆) -> d(纤) -> e(杆)
  // 地理：a(114.0,32.0) b(114.001,32.0) c(114.002,32.0) d(114.002,31.999) e(114.003,31.999)
  // 走向：东、东、南、东
  List<MapLabel> fullRoute() => [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('b', '纤1', 2, 32.0, 114.001),
        dev('c', '杆2', 3, 32.0, 114.002),
        dev('d', '纤2', 4, 31.999, 114.002),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];

  group('layoutWiringDiagram（整条路由直角简化，2026-10-08）', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], [], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
      expect(l.path, isEmpty);
    });

    test('路径跟整条路由走（含中间杆转弯）', () {
      final route = fullRoute();
      // 纤设备只有 b 和 d
      final ds = [
        dev('b', '纤1', 2, 32.0, 114.001),
        dev('d', '纤2', 4, 31.999, 114.002),
      ];
      final ls = [FiberLink(fromDeviceId: 'b', toDeviceId: 'd')];
      final l = layoutWiringDiagram(ds, ls, route);
      // 路径有 5 个点（整条路由）
      expect(l.path.length, 5);
      // 路径走向：东、东、南、东
      // p0->p1: 东（x+）
      expect(l.path[1].x > l.path[0].x, isTrue);
      // p2->p3: 南（y-）
      expect(l.path[3].y < l.path[2].y, isTrue);
      // 纤设备 b 在路径点1，d 在路径点3
      final byId = {for (final n in l.nodes) n.device.id: n};
      expect(byId['b']!.x, l.path[1].x);
      expect(byId['b']!.y, l.path[1].y);
      expect(byId['d']!.x, l.path[3].x);
      expect(byId['d']!.y, l.path[3].y);
    });

    test('无效连线被过滤', () {
      final route = fullRoute();
      final ds = [dev('b', '纤1', 2, 32.0, 114.001)];
      final ls = [FiberLink(fromDeviceId: 'b', toDeviceId: 'zzz')];
      final l = layoutWiringDiagram(ds, ls, route);
      expect(l.nodes.length, 1);
      expect(l.edges, isEmpty);
    });

    test('段长=真实地理距离×统一缩放，方向与地理一致（2026-10-10 走向相同整体缩小）', () {
      final route = fullRoute();
      final ds = [
        dev('b', '纤1', 2, 32.0, 114.001),
        dev('d', '纤2', 4, 31.999, 114.002),
      ];
      final ls = [FiberLink(fromDeviceId: 'b', toDeviceId: 'd')];
      // 默认 uniformScale=0.5
      final l = layoutWiringDiagram(ds, ls, route);
      double drawLen(int i) {
        final dx = l.path[i + 1].x - l.path[i].x;
        final dy = l.path[i + 1].y - l.path[i].y;
        return math.sqrt(dx * dx + dy * dy);
      }

      double geoLen(double lon1, double lat1, double lon2, double lat2) {
        final avgLat = (lat1 + lat2) / 2;
        final cosLat = math.cos(avgLat * math.pi / 180);
        final dxM = (lon2 - lon1) * 111000.0 * cosLat;
        final dyM = (lat2 - lat1) * 111000.0;
        return math.sqrt(dxM * dxM + dyM * dyM);
      }

      // 四段长度 = 真实地理距离 × 0.5（统一缩放），不是固定40，也不是真1:1
      const kScale = 0.5;
      expect(drawLen(0),
          closeTo(geoLen(114.0, 32.0, 114.001, 32.0) * kScale, 0.001));
      expect(drawLen(1),
          closeTo(geoLen(114.001, 32.0, 114.002, 32.0) * kScale, 0.001));
      expect(drawLen(2),
          closeTo(geoLen(114.002, 32.0, 114.002, 31.999) * kScale, 0.001));
      expect(drawLen(3),
          closeTo(geoLen(114.002, 31.999, 114.003, 31.999) * kScale, 0.001));
      // 方向保留：第一段纯东向（dy≈0），第三段纯南向（dx≈0），非直角量化也能对上
      final dx0 = l.path[1].x - l.path[0].x;
      final dy0 = l.path[1].y - l.path[0].y;
      expect(dy0.abs(), lessThan(0.001)); // 东向
      expect(dx0, greaterThan(0));
      final dx2 = l.path[3].x - l.path[2].x;
      final dy2 = l.path[3].y - l.path[2].y;
      expect(dx2.abs(), lessThan(0.001)); // 南向
      expect(dy2, lessThan(0));
    });
  });
}
