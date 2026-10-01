// 建筑兜底包：bbox 查询过滤 + OSM/兜底合并去重（零网络）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/building_fallback.dart';

const _geojson = '''
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[114.0,32.1],[114.001,32.1],[114.001,32.101],[114.0,32.1]]]}},
{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[115.5,32.5],[115.501,32.5],[115.501,32.501],[115.5,32.5]]]}},
{"type":"Feature","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[[[[114.02,32.12],[114.021,32.12],[114.021,32.121],[114.02,32.12]]]]}}
]}''';

Future<FallbackStore> _storeWithPkg() async {
  final dir = await Directory.systemTemp.createTemp('ovimap_fb');
  final fb = Directory('${dir.path}/fallback')..createSync();
  File('${fb.path}/xinyang.geojson').writeAsStringSync(_geojson);
  File('${fb.path}/index.json').writeAsStringSync(jsonEncode({
    'id': 'xinyang',
    'name': '信阳市',
    'version': 'v1',
    'source': 'CMAB v7',
    'buildings': 3,
  }));
  return FallbackStore(fb);
}

List<List<List<double>>> _ring(double lat, double lon, double d) => [
      [
        [lat, lon],
        [lat, lon + d],
        [lat + d, lon + d],
        [lat, lon],
      ]
    ];

void main() {
  test('meta/hasPackage：索引读写', () async {
    final s = await _storeWithPkg();
    expect(s.hasPackage, isTrue);
    expect(s.meta()?['name'], '信阳市');
    expect(s.meta()?['buildings'], 3);
  });

  test('query：只返回 bbox 相交建筑', () async {
    final s = await _storeWithPkg();
    // bbox 覆盖第一栋 + MultiPolygon，不含第二栋
    final r = await s.query([32.0, 113.9, 32.2, 114.1]);
    expect(r.length, 2);
    // 点序为 [lat, lon]
    expect(r[0].outer[0][0], closeTo(32.1, 1e-9));
    expect(r[0].outer[0][1], closeTo(114.0, 1e-9));
  });

  test('query：bbox 无交集返回空', () async {
    final s = await _storeWithPkg();
    final r = await s.query([30.0, 110.0, 30.1, 110.1]);
    expect(r, isEmpty);
  });

  test('query：未安装返回空', () async {
    final dir = await Directory.systemTemp.createTemp('ovimap_fb_empty');
    final s = FallbackStore(dir);
    expect(s.hasPackage, isFalse);
    expect(await s.query([32.0, 113.9, 32.2, 114.1]), isEmpty);
  });

  test('mergeBuildings：OSM 优先，兜底只补缺', () {
    final osm = [BuildingPoly(_ring(32.1, 114.0, 0.001), 'osm楼')];
    final fb = [
      // 与 OSM 同一栋（质心 <15m）→ 去重
      BuildingPoly(_ring(32.10002, 114.00002, 0.001), ''),
      // 远处 → 补上
      BuildingPoly(_ring(32.2, 114.1, 0.001), ''),
    ];
    final merged = BasemapFetcher.mergeBuildings(osm, fb);
    expect(merged.length, 2);
    expect(merged[0].name, 'osm楼'); // OSM 保留在前
  });

  test('mergeBuildings：OSM 为空时全量保留', () {
    final fb = [BuildingPoly(_ring(32.2, 114.1, 0.001), '')];
    expect(BasemapFetcher.mergeBuildings([], fb).length, 1);
  });
}
