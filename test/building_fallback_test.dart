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

  // —— 后台更新：manifest 比对 + 自动替换（全 mock，零网络）——

const testPkg = FallbackPackage(
  id: 'xinyang',
  name: '信阳市',
  manifestUrl: 'https://example.invalid/manifest.json',
  source: 'CMAB v7',
);

Map<String, dynamic> manifestOf(int version) => {
      'id': 'xinyang',
      'name': '信阳市',
      'version': version,
      'url': 'https://example.invalid/xinyang_buildings.geojson.gz',
      'bytes': 12345,
      'buildings': 98006,
      'source': 'CMAB v7',
      'updated': '2026-10-02',
    };

/// mock HTTP：manifest 按 [manifestVersion] 返回，数据文件返回 gzip 后的 [_geojson]。
void mockHttp({required int manifestVersion, bool fail = false}) {
  FallbackStore.httpGetOverride = (Uri url) async {
    if (fail) return (statusCode: 500, body: <int>[]);
    if (url.path.endsWith('manifest.json')) {
      return (
        statusCode: 200,
        body: utf8.encode(jsonEncode(manifestOf(manifestVersion))),
      );
    }
    return (
      statusCode: 200,
      body: gzip.encode(utf8.encode(_geojson)),
    );
  };
}

  test('FallbackRelease.parse：合法 manifest 解析', () {
    final r = FallbackRelease.parse(manifestOf(2));
    expect(r, isNotNull);
    expect(r!.version, 2);
    expect(r.url, contains('.gz'));
    expect(r.buildings, 98006);
  });

  test('FallbackRelease.parse：非法 manifest 返回 null', () {
    expect(FallbackRelease.parse({}), isNull);
    expect(FallbackRelease.parse({'version': 0, 'url': ''}), isNull);
  });

  test('meta：旧版字符串版本 v1 兼容为 int 1', () async {
    final s = await _storeWithPkg(); // index.json 里 version: 'v1'
    expect(s.meta()?['version'], 1);
  });

  test('checkForUpdates：本地 v1、远端 v2 → 有更新', () async {
    mockHttp(manifestVersion: 2);
    final s = await _storeWithPkg();
    final updates = await s.checkForUpdates();
    expect(updates.length, 1);
    expect(updates[0].fromVersion, 1);
    expect(updates[0].release.version, 2);
    FallbackStore.httpGetOverride = null;
  });

  test('checkForUpdates：版本一致 → 无更新', () async {
    mockHttp(manifestVersion: 1);
    final s = await _storeWithPkg();
    expect(await s.checkForUpdates(), isEmpty);
    FallbackStore.httpGetOverride = null;
  });

  test('checkForUpdates：网络失败 → 空列表且不抛异常', () async {
    mockHttp(manifestVersion: 2, fail: true);
    final s = await _storeWithPkg();
    expect(await s.checkForUpdates(), isEmpty);
    FallbackStore.httpGetOverride = null;
  });

  test('update：下载替换并升级版本号（原子）', () async {
    mockHttp(manifestVersion: 2);
    final s = await _storeWithPkg();
    final rel = await s.fetchRelease(testPkg);
    expect(rel, isNotNull);
    await s.update(testPkg, rel!);
    final m = s.meta();
    expect(m?['version'], 2);
    expect(m?['buildings'], 3);
    // 新包装上了：bbox 查询仍可用
    expect(await s.query([32.0, 113.9, 32.2, 114.1]), hasLength(2));
    FallbackStore.httpGetOverride = null;
  });

  test('update：坏包不破坏旧包', () async {
    FallbackStore.httpGetOverride = (Uri url) async {
      if (url.path.endsWith('manifest.json')) {
        return (
          statusCode: 200,
          body: utf8.encode(jsonEncode(manifestOf(2))),
        );
      }
      return (statusCode: 200, body: utf8.encode('not a gzip'));
    };
    final s = await _storeWithPkg();
    final rel = await s.fetchRelease(testPkg);
    expect(() => s.update(testPkg, rel!), throwsA(isA<FormatException>()));
    // 旧包仍在、版本未动
    expect(s.meta()?['version'], 1);
    expect(await s.query([32.0, 113.9, 32.2, 114.1]), hasLength(2));
    FallbackStore.httpGetOverride = null;
  });

  test('ensureLatest：有更新自动装，无更新返回 0，失败不抛', () async {
    mockHttp(manifestVersion: 3);
    final s = await _storeWithPkg();
    expect(await s.ensureLatest(), 1);
    expect(s.meta()?['version'], 3);
    // 再次调用：已是最新
    expect(await s.ensureLatest(), 0);
    FallbackStore.httpGetOverride = null;

    mockHttp(manifestVersion: 9, fail: true);
    expect(await s.ensureLatest(), 0); // 不抛
    FallbackStore.httpGetOverride = null;
  });

  test('install：走 manifest 拿地址与版本', () async {
    mockHttp(manifestVersion: 2);
    final dir = await Directory.systemTemp.createTemp('ovimap_fb_new');
    final s = FallbackStore(dir);
    await s.install(testPkg);
    expect(s.meta()?['version'], 2);
    expect(s.meta()?['buildings'], 3);
    FallbackStore.httpGetOverride = null;
  });
}
