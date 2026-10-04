// 改造三态（原有/新增/拆除）：数据模型 + DXF 分层 + 工程量统计。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/models/reno_state.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';

final store = LabelStore.instance;

/// DXF 文件为 GBK 编码，读文本先解码。
String readDxf(File f) => gbk_bytes.decode(f.readAsBytesSync());

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_reno');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dxfSurroundings': false,
      'dxfUseLocal': false,
    });
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('RenoState 标签', () {
    expect(RenoState.label(0), '原有');
    expect(RenoState.label(1), '新增');
    expect(RenoState.label(2), '拆除');
    expect(RenoState.label(99), '原有');
  });

  test('MapLabel reno JSON 回环', () {
    final l = MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0)..reno = 1;
    final j = l.toJson();
    expect(j['reno'], 1);
    final back = MapLabel.fromJson(j);
    expect(back.reno, 1);
    expect(l.clone().reno, 1);
    // 老数据（无 reno 键）默认为原有
    final old = MapLabel.fromJson({'typeId': 'pipe'});
    expect(old.reno, RenoState.existing);
    // reno=0 时不写盘（纯加法）
    expect(MapLabel(typeId: 'pipe').toJson().containsKey('reno'), false);
  });

  test('FiberLink reno JSON 回环', () {
    final l = FiberLink(fromDeviceId: 'a', toDeviceId: 'b')..reno = 2;
    final j = l.toJson();
    expect(j['reno'], 2);
    final back = FiberLink.fromJson(j);
    expect(back.reno, 2);
    expect(l.clone().reno, 2);
    final old = FiberLink.fromJson({});
    expect(old.reno, RenoState.existing);
    expect(FiberLink().toJson().containsKey('reno'), false);
  });

  test('DXF 改造三态分层 + 虚实线 + 统计', () async {
    // 3 段杆路：原有 / 新增 / 拆除（reno 记在终点 = 本点入段）
    MapLabel pole(int seq, double lat, double lon, String name, [int reno = 0]) =>
        MapLabel(
            typeId: 'pole',
            seq: seq,
            lat: lat,
            lon: lon,
            name: name,
            lineGroupId: 'g1')
          ..reno = reno;
    final labels = [
      pole(1, 32.0, 114.0, 'G1'),
      pole(2, 32.001, 114.001, 'G2', RenoState.added),
      pole(3, 32.002, 114.002, 'G3', RenoState.removed),
      pole(4, 32.003, 114.003, 'G4'),
    ];
    final r = await DxfExporter.export(
      name: 'reno_test',
      labels: labels,
      includeSurroundings: false,
      showLegend: false,
    );
    final dxf = readDxf(r.file);

    // 三态独立成层
    expect(dxf.contains('\nGanLu\n'), true);
    expect(dxf.contains('\nGanLuNew\n'), true);
    expect(dxf.contains('\nGanLuRemove\n'), true);
    // 拆除层用 DASHED 线型，且线型表已定义
    expect(dxf.contains('\nDASHED\n'), true);
    // 统计：新增 1 段、拆除 1 段，原有不计入
    expect(r.renoNewLenM, greaterThan(0));
    expect(r.renoRemoveLenM, greaterThan(0));
    // 拆除段长度 ≈ 新增段长度（等距打点）
    expect((r.renoNewLenM - r.renoRemoveLenM).abs() < 5, true);
    // DXF 内有改造工程量注记
    expect(dxf.contains('杆路改造'), true);
  });

  test('DXF 光缆三态分层 + 统计', () async {
    final d1 = MapLabel(typeId: 'odf', seq: 1, lat: 32.0, lon: 114.0, name: 'A')
      ..id = 'd1';
    final d2 = MapLabel(typeId: 'odf', seq: 2, lat: 32.001, lon: 114.001, name: 'B')
      ..id = 'd2';
    final d3 = MapLabel(typeId: 'odf', seq: 3, lat: 32.002, lon: 114.002, name: 'C')
      ..id = 'd3';
    final links = [
      FiberLink(fromDeviceId: 'd1', toDeviceId: 'd2', lengthM: 100)
        ..reno = RenoState.added,
      FiberLink(fromDeviceId: 'd2', toDeviceId: 'd3', lengthM: 200)
        ..reno = RenoState.removed,
    ];
    final r = await DxfExporter.export(
      name: 'reno_fiber_test',
      labels: [d1, d2, d3],
      includeSurroundings: false,
      showLegend: false,
      fiberLinks: links,
    );
    final dxf = readDxf(r.file);
    expect(dxf.contains('\nPeiXianTuNew\n'), true);
    expect(dxf.contains('\nPeiXianTuRemove\n'), true);
    expect(r.fiberNewLenM, 100);
    expect(r.fiberRemoveLenM, 200);
    expect(dxf.contains('光缆改造'), true);
  });

  test('无改造时不画注记、不影响原有图层', () async {
    final labels = [
      MapLabel(
          typeId: 'pole', seq: 1, lat: 32.0, lon: 114.0, lineGroupId: 'g1'),
      MapLabel(
          typeId: 'pole', seq: 2, lat: 32.001, lon: 114.001, lineGroupId: 'g1'),
    ];
    final r = await DxfExporter.export(
      name: 'reno_none_test',
      labels: labels,
      includeSurroundings: false,
      showLegend: false,
    );
    final dxf = readDxf(r.file);
    expect(r.renoNewLenM, 0);
    expect(r.renoRemoveLenM, 0);
    expect(dxf.contains('杆路改造'), false);
    expect(dxf.contains('\nGanLu\n'), true);
  });
}
