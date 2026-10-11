import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('端到端：含拓扑的工程导出 DXF（配线图沿杆路走向 + GBK）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final gid = 'g1';
    final labels = <MapLabel>[];
    final offsets = [
      (0.0, 0.0), (0.0004, 0.0002), (0.0009, 0.0005), (0.0013, 0.0011),
      (0.0015, 0.0018), (0.0013, 0.0024), (0.0008, 0.0028), (0.0002, 0.0030),
    ];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
          typeId: 'pipe',
          seq: i + 1,
          lat: 32.1264 + offsets[i].$1,
          lon: 114.0913 + offsets[i].$2,
          lineGroupId: gid,
          distLabel: i == 2 ? '埋42.5' : ''));
    }
    final cross = MapLabel(
        typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
    final split = MapLabel(
        typeId: 'splitterbox',
        seq: 10,
        lat: 32.1279,
        lon: 114.0931,
        name: '李庄分光箱',
        splitterRatio: '1:8');
    final fiber = MapLabel(
        typeId: 'fiberbox', seq: 11, lat: 32.1266, lon: 114.0943, name: '李庄分纤盒');
    split.topoParentId = cross.id;
    fiber.topoParentId = split.id;
    split.cableSpec = '架24芯GYTS-01';
    fiber.cableSpec = '架12芯GYTS-02';
    labels.addAll([cross, split, fiber]);

    final r = await DxfExporter.export(
        name: '拓扑测试',
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12);
    final f = r.file;
    final bytes = f.readAsBytesSync();
    final text = gbk_bytes.decode(bytes);

    expect(r.warnings, isEmpty);
    expect(text, contains(r'$DWGCODEPAGE'));
    expect(text, contains('ANSI_936'));
    expect(text, contains('PeiXianTu'));
    // 配线图：箱体落位 + 名称 + 光缆型号 + 箱体间距离
    expect(text, contains('李庄光交'));
    expect(text, contains('李庄分光箱'));
    expect(text, contains('李庄分纤盒'));
    expect(text, contains('架24芯GYTS-01'));
    expect(text, contains('架12芯GYTS-02'));
    expect(text, contains('237.8')); // 光交→分光箱 箱体间距离
    expect(text, contains('183.5')); // 分光箱→分纤盒 箱体间距离
    // P0-6：ODN 合成的 FiberLink 带业务字段 → 新配线图有型号与"长xx"标注
    // cableSpec "架24芯GYTS-01" → 型号 "24芯GYTS-01（架空）"，段长=两端点地理距离
    expect(text, contains('24芯GYTS-01（架空）'));
    expect(text, contains('12芯GYTS-02（架空）'));
    expect(text, contains('长237.8'));
    expect(text, contains('长183.5'));
    // P1-15/P1-16：'2\nHZ_FIBERBOX' = 块定义 + 路由图符号 + 图例 + 配线图，
    // 有名字的分纤盒也不再按名字长度自适应画框
    expect('2\nHZ_FIBERBOX'.allMatches(text).length, 4);
    // R12 兼容：多段线用经典 POLYLINE（不再用 LWPOLYLINE），主干宽 0.6
    expect(text, contains('0\nPOLYLINE'));
    expect(text, isNot(contains('LWPOLYLINE')));
    expect(text, contains('40\n0.600'));
    // 图例 + 指北针图层（2026-10-05：标题栏已按用户要求删除，不再断言其内容）
    expect(text, contains('TuQian'));
    expect(text, contains('BeiFangZhen'));
    expect(text, isNot(contains('滑洲云图')));
    expect(text, isNot(contains('设计单位')));
    // 正规槽位箱符号（2026-10-08）：分纤盒用 HZ_FIBERBOX（10×4.4），带 2槽位箱文字
    expect(text, contains('HZ_FIBERBOX'));
    expect(text, contains('2槽位箱'));
    // 杆路段标注前缀文字
    expect(text, contains('埋42.5'));
    // GBK 字节验证：'李' = 0xC0 0xEE
    expect(bytes, containsAllInOrder([0xC0, 0xEE]));
    print('DXF 端到端生成成功: ${f.path} ${bytes.length} 字节');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('P0-8：桩号字高按纸面毫米换算（小线路 1:100 下字高 0.25m）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    // 10 米线路 → _pickScale 得 100；此前桩号字高裸写 2.5（米），
    // 1:100 下打印出来 25mm 巨大；现应为 2.5mm → 0.25m。
    final labels = [
      MapLabel(
          typeId: 'pipe',
          seq: 1,
          lat: 32.1264,
          lon: 114.0913,
          lineGroupId: 'g1'),
      MapLabel(
          typeId: 'pipe',
          seq: 2,
          lat: 32.1264 + 10 / 110540.0,
          lon: 114.0913,
          lineGroupId: 'g1'),
    ];
    final r = await DxfExporter.export(
        name: '桩号测试',
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12);
    final text = gbk_bytes.decode(r.file.readAsBytesSync());

    expect(text, contains('ZhuangHao'));
    expect(text, contains('K0+'));
    // 桩号是唯一的 ZhuangHao 层实体：逐个 TEXT 实体找字高组码 40
    double? stakeH;
    for (final seg in text.split('0\nTEXT\n')) {
      if (!seg.startsWith('8\nZhuangHao\n')) continue;
      final m = RegExp(r'\n40\n([\d.]+)\n').firstMatch(seg);
      if (m != null) stakeH = double.parse(m.group(1)!);
    }
    expect(stakeH, isNotNull, reason: '应找到桩号文字实体');
    expect(stakeH!, closeTo(0.25, 1e-9), reason: '2.5mm @ 1:100 = 0.25m');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('P0-11：自动挂载边不在地理式配线里画（与配线图口径一致）', () async {
    final dir = Directory.systemTemp.createTempSync('ovimap');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    final gid = 'g1';
    final labels = <MapLabel>[];
    final offsets = [
      (0.0, 0.0), (0.0004, 0.0002), (0.0009, 0.0005), (0.0013, 0.0011),
      (0.0015, 0.0018), (0.0013, 0.0024), (0.0008, 0.0028), (0.0002, 0.0030),
    ];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
          typeId: 'pipe',
          seq: i + 1,
          lat: 32.1264 + offsets[i].$1,
          lon: 114.0913 + offsets[i].$2,
          lineGroupId: gid));
    }
    final cross = MapLabel(
        typeId: 'crossbox', seq: 9, lat: 32.1264, lon: 114.0913, name: '李庄光交');
    final split = MapLabel(
        typeId: 'splitterbox',
        seq: 10,
        lat: 32.1279,
        lon: 114.0931,
        name: '李庄分光箱',
        splitterRatio: '1:8');
    split.topoParentId = cross.id;
    split.cableSpec = '架24芯GYTS-01';
    // 自动挂载节点：无 topoParentId，按 seq 会被 buildTree 自动挂到分光箱下；
    // P0-11 口径：地理式配线与新配线图都只认显式边，这条边两边都不画
    final auto = MapLabel(
        typeId: 'fiberbox', seq: 11, lat: 32.1310, lon: 114.0980, name: '自动分纤盒');
    labels.addAll([cross, split, auto]);

    final r = await DxfExporter.export(
        name: '自动挂载测试',
        labels: labels,
        includeSurroundings: false,
        version: DxfVersion.r12);
    final text = gbk_bytes.decode(r.file.readAsBytesSync());

    // 显式边仍在：光交→分光箱距离标注
    expect(text, contains('237.8'));
    // 自动边（分光箱→自动分纤盒）的距离标注不应出现
    final autoDist = _hav(32.1279, 114.0931, 32.1310, 114.0980).toStringAsFixed(1);
    expect(text, isNot(contains(autoDist)), reason: '自动挂载边不应画出（P0-11）');
    // 自动节点的标签牌仍在（只画牌，不画边）
    expect(text, contains('自动分纤盒'));
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// haversine（米），与 DxfExporter._haversine 同公式，供测试算期望距离。
double _hav(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(la2 - la1);
  final dLon = rad(lo2 - lo1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(la1)) * math.cos(rad(la2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
