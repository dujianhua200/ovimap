import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/csv.dart';
import 'package:ovimap/geo/geo_util.dart';
import 'package:ovimap/models/diff_report.dart';
import 'package:ovimap/models/map_label.dart';

/// 竣工对比（Phase 5）第二批测试：阈值边界、杆位四态、段长变化计算。
///
/// 标红口径（与 `showDesignDiffDialog` 一致）：
///
/// · 杆位：状态 moved（偏移 > 阈值）→ 红；偏移 = 阈值（边界）→ same，不红；
/// · 段长：|Δ| > 阈值 → 红；= 阈值（边界）→ 不红。
void main() {
  MapLabel pole(String name, double lat, double lon, {String dist = ''}) =>
      MapLabel(
          typeId: 'pipe',
          lat: lat,
          lon: lon,
          name: name,
          lineGroupId: 'g',
          distLabel: dist);

  group('阈值边界（= 阈值不标红、> 阈值标红）', () {
    test('杆位：偏移恰好 = 阈值时为 same，不标红', () {
      final design = [pole('GK-1', 32.0, 114.0)];
      final comp = [pole('GK-1', 32.001, 114.0)];
      final off = GeoUtil.haversine(32.0, 114.0, 32.001, 114.0);
      expect(off, greaterThan(0));

      final r = CsvExporter.buildDesignDiff(design, comp,
          offsetThreshold: off);
      final p = r.poles.singleWhere((e) => e.key == 'GK-1');
      expect(p.status, DiffStatus.same, reason: 'off == 阈值 → 一致');
      expect(diffPoleOverThreshold(p), isFalse, reason: '边界不标红');
    });

    test('杆位：偏移 > 阈值时为 moved，标红', () {
      final design = [pole('GK-1', 32.0, 114.0)];
      final comp = [pole('GK-1', 32.001, 114.0)];
      final off = GeoUtil.haversine(32.0, 114.0, 32.001, 114.0);

      final r = CsvExporter.buildDesignDiff(design, comp,
          offsetThreshold: off - 1e-6);
      final p = r.poles.singleWhere((e) => e.key == 'GK-1');
      expect(p.status, DiffStatus.moved);
      expect(p.offsetM, closeTo(off, 1e-6));
      expect(diffPoleOverThreshold(p), isTrue, reason: '超阈标红');
    });

    test('段长：|Δ| 恰好 = 阈值时不标红，> 阈值时标红', () {
      const seg = DiffSegItem(
          seg: 'GK-1>GK-2', designM: 100, compM: 110, deltaM: 10);
      expect(diffSegOverThreshold(seg, 10.0), isFalse,
          reason: '|Δ| == 阈值 → 不标红');
      expect(diffSegOverThreshold(seg, 9.9999), isTrue,
          reason: '|Δ| > 阈值 → 标红');
      const neg = DiffSegItem(
          seg: 'GK-2>GK-3', designM: 110, compM: 100, deltaM: -10);
      expect(diffSegOverThreshold(neg, 10.0), isFalse);
      expect(diffSegOverThreshold(neg, 9.9999), isTrue,
          reason: '负向偏差同样取绝对值判定');
    });

    test('段长：同名杆段 Δ 恰好 = 阈值时整行不标红', () {
      final design = [
        pole('GK-1', 32.0, 114.0, dist: '0'),
        pole('GK-2', 32.001, 114.0, dist: '100'),
      ];
      final comp = [
        pole('GK-1', 32.0, 114.0, dist: '0'),
        pole('GK-2', 32.001, 114.0, dist: '110'),
      ];
      final r = CsvExporter.buildDesignDiff(design, comp);
      final seg = r.segs.singleWhere((s) => s.seg == 'GK-1>GK-2');
      expect(seg.deltaM, closeTo(10.0, 1e-9));
      expect(diffSegOverThreshold(seg, 10.0), isFalse);
      expect(diffSegOverThreshold(seg, 5.0), isTrue);
    });
  });

  group('杆位四态（added/removed/moved/same）', () {
    List<MapLabel> design() => [
          pole('GK-1', 32.0, 114.0), // 竣工同位置 → same
          pole('GK-2', 32.001, 114.0), // 竣工偏移 → moved
          pole('GK-3', 32.002, 114.0), // 竣工缺失 → removed
        ];
    List<MapLabel> completion() => [
          pole('GK-1', 32.0, 114.0),
          pole('GK-2', 32.0011, 114.0), // ≈11m > 阈值 10m
          pole('GK-4', 32.003, 114.0), // 新增 → added
        ];

    DiffPoleItem byKey(DesignDiffReport r, String k) =>
        r.poles.singleWhere((p) => p.key == k);

    test('四态状态与标红判定一致', () {
      final r =
          CsvExporter.buildDesignDiff(design(), completion(),
              offsetThreshold: 10.0);
      final same = byKey(r, 'GK-1');
      final moved = byKey(r, 'GK-2');
      final removed = byKey(r, 'GK-3');
      final added = byKey(r, 'GK-4');

      expect(same.status, DiffStatus.same);
      expect(moved.status, DiffStatus.moved);
      expect(removed.status, DiffStatus.removed);
      expect(added.status, DiffStatus.added);

      // 只有 moved（超阈偏移）标红
      expect(diffPoleOverThreshold(same), isFalse);
      expect(diffPoleOverThreshold(moved), isTrue);
      expect(diffPoleOverThreshold(removed), isFalse);
      expect(diffPoleOverThreshold(added), isFalse);
    });

    test('放大阈值后 moved 降级为 same 且不再标红', () {
      final r = CsvExporter.buildDesignDiff(design(), completion(),
          offsetThreshold: 1000.0);
      final p = byKey(r, 'GK-2');
      expect(p.status, DiffStatus.same);
      expect(diffPoleOverThreshold(p), isFalse);
      expect(r.summary.moved, 0);
      expect(r.summary.kept, 2);
    });

    test('四态坐标缺失侧为 null', () {
      final r =
          CsvExporter.buildDesignDiff(design(), completion(),
              offsetThreshold: 10.0);
      final added = byKey(r, 'GK-4');
      expect(added.dLat, isNull);
      expect(added.cLat, isNotNull);
      final removed = byKey(r, 'GK-3');
      expect(removed.dLat, isNotNull);
      expect(removed.cLat, isNull);
    });
  });

  group('段长变化（光缆长度变化）计算', () {
    test('同名相邻杆段 Δ = 竣工 − 设计（标注口径优先）', () {
      // segLenLabelFirst 取终点 b 的 distLabel 数值作为段长。
      final design = [
        pole('GK-1', 32.0, 114.0, dist: '0'),
        pole('GK-2', 32.001, 114.0, dist: '100'),
        pole('GK-3', 32.002, 114.0, dist: '210'),
      ];
      final comp = [
        pole('GK-1', 32.0, 114.0, dist: '0'),
        pole('GK-2', 32.001, 114.0, dist: '120'),
        pole('GK-3', 32.002, 114.0, dist: '230'),
      ];
      final r = CsvExporter.buildDesignDiff(design, comp);
      final s12 = r.segs.singleWhere((s) => s.seg == 'GK-1>GK-2');
      final s23 = r.segs.singleWhere((s) => s.seg == 'GK-2>GK-3');
      expect(s12.designM, closeTo(100, 1e-9));
      expect(s12.compM, closeTo(120, 1e-9));
      expect(s12.deltaM, closeTo(20, 1e-9));
      expect(s23.designM, closeTo(210, 1e-9));
      expect(s23.compM, closeTo(230, 1e-9));
      expect(s23.deltaM, closeTo(20, 1e-9));
      // 净长度差 = Σ竣工段距 − Σ设计段距 = (120+230) − (100+210)
      expect(r.summary.netLenDiffM, closeTo(40, 1e-6));
    });

    test('段长偏差超阈判定走 |Δ| 口径', () {
      final design = [
        pole('A', 32.0, 114.0, dist: '0'),
        pole('B', 32.001, 114.0, dist: '100'),
      ];
      final comp = [
        pole('A', 32.0, 114.0, dist: '0'),
        pole('B', 32.001, 114.0, dist: '92'),
      ];
      final r = CsvExporter.buildDesignDiff(design, comp);
      final seg = r.segs.single;
      expect(seg.deltaM, closeTo(-8, 1e-9));
      expect(diffSegOverThreshold(seg, 5.0), isTrue, reason: '|−8| > 5 标红');
      expect(diffSegOverThreshold(seg, 8.0), isFalse, reason: '边界不标红');
    });
  });
}
