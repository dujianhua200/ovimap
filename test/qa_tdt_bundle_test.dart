// 天地图补充包（村名/小队名 + 干线道路）加载与去重验证。
//
// 数据来源：tool/tdt_pack.py 从天地图 v2/search + WFS LRDL 采集打包，
// 断言点：
//  1. 两个补充包能加载（asset 缺失时不至于整包失效）；
//  2. 地名确实补进来了（比 OSM 包多），且「塆」类自然村名成规模；
//  3. 道路比 OSM 包多（天地图补了 OSM 没覆盖的走廊）；
//  4. 跨包同名同地不重复（去重生效，DXF 不会一个村子标两个名字）。
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/export/bundled_basemap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    BundledBasemap.enabled = true;
    BundledBasemap.resetForTest();
  });

  tearDown(() {
    BundledBasemap.enabled = false;
    BundledBasemap.resetForTest();
  });

  test('天地图补充包：地名与道路均加载，且跨包同名同地去重', () async {
    final b = await BundledBasemap.instance;
    expect(b.loaded, isTrue, reason: '内置包应能加载道路/地名');

    final places = b.placesIn(kXinyangLonMin, kXinyangLatMin,
        kXinyangLonMax, kXinyangLatMax);
    // OSM 包 8633 条 + 天地图补充 23392 条，按同名 110m 去重后约 3.1 万条。
    expect(places.length, greaterThan(25000),
        reason: '天地图补充包未合并进地名（当前 ${places.length} 条）');

    final wan = places.where((p) => p.name.endsWith('塆')).length;
    expect(wan, greaterThan(6000),
        reason: '豫南自然村「××塆」应成规模（当前 $wan 条）');

    // 跨包去重：同名且 110m 内不应出现两次（0.002° ≈ 220m 作为宽松桶）。
    final buckets = <String, int>{};
    for (final p in places) {
      final k = '${p.name}@${p.lat.toStringAsFixed(3)},'
          '${p.lon.toStringAsFixed(3)}';
      buckets[k] = (buckets[k] ?? 0) + 1;
    }
    final dup = buckets.entries.where((e) => e.value > 1).toList();
    expect(dup.length, lessThan(places.length * 0.02),
        reason: '同名同地重复过多（${dup.length} 组），跨包去重失效：'
            '${dup.take(3).map((e) => e.key).join(' / ')}');

    final roads = b.roadsIn(kXinyangLonMin, kXinyangLatMin,
        kXinyangLonMax, kXinyangLatMax);
    // OSM 包 4501 条；天地图补充后应更多（已被 OSM 覆盖的路段会跳过）。
    expect(roads.length, greaterThan(4501),
        reason: '天地图道路未合并（当前 ${roads.length} 条）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
